#include "pch.h"
#include "CredentialStore.h"

namespace
{
    constexpr wchar_t CredentialPrefix[] = L"LibChess/OAuth/";

    class CredentialBuffer final
    {
    public:
        explicit CredentialBuffer(PCREDENTIALW credential) noexcept : credential_(credential) {}

        ~CredentialBuffer()
        {
            if (credential_)
            {
                if (credential_->CredentialBlob && credential_->CredentialBlobSize > 0)
                {
                    SecureZeroMemory(
                        credential_->CredentialBlob,
                        credential_->CredentialBlobSize);
                }
                CredFree(credential_);
            }
        }

        CredentialBuffer(CredentialBuffer const&) = delete;
        CredentialBuffer& operator=(CredentialBuffer const&) = delete;

        PCREDENTIALW get() const noexcept
        {
            return credential_;
        }

    private:
        PCREDENTIALW credential_;
    };

    class SensitiveBytes final
    {
    public:
        explicit SensitiveBytes(std::string bytes) : bytes_(std::move(bytes)) {}

        ~SensitiveBytes()
        {
            if (!bytes_.empty())
            {
                SecureZeroMemory(bytes_.data(), bytes_.size());
            }
        }

        SensitiveBytes(SensitiveBytes const&) = delete;
        SensitiveBytes& operator=(SensitiveBytes const&) = delete;

        std::string const& get() const noexcept
        {
            return bytes_;
        }

    private:
        std::string bytes_;
    };

    std::runtime_error CredentialError(char const* message)
    {
        return std::runtime_error(message);
    }

    bool AccessTokenIsValid(std::string const& token)
    {
        return !token.empty() && token.size() <= CRED_MAX_CREDENTIAL_BLOB_SIZE &&
            std::all_of(token.begin(), token.end(), [](unsigned char byte)
            {
                return (byte >= 'a' && byte <= 'z') ||
                    (byte >= 'A' && byte <= 'Z') ||
                    (byte >= '0' && byte <= '9') ||
                    std::string_view("-._~+/=").find(static_cast<char>(byte)) !=
                        std::string_view::npos;
            });
    }
}

namespace LibChess::Windows
{
    std::wstring CredentialStore::Target(winrt::hstring const& provider)
    {
        if (provider.empty() || provider.size() > 64)
        {
            throw CredentialError("The online service identifier is invalid.");
        }
        for (auto const character : provider)
        {
            auto const valid =
                (character >= L'a' && character <= L'z') ||
                (character >= L'0' && character <= L'9') ||
                character == L'-' || character == L'_';
            if (!valid)
            {
                throw CredentialError("The online service identifier is invalid.");
            }
        }
        return std::wstring(CredentialPrefix) + std::wstring(provider);
    }

    bool CredentialStore::Contains(winrt::hstring const& provider)
    {
        auto const target = Target(provider);
        PCREDENTIALW raw_credential = nullptr;
        if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &raw_credential))
        {
            if (GetLastError() == ERROR_NOT_FOUND)
            {
                return false;
            }
            throw CredentialError("Windows couldn't read the saved sign-in.");
        }
        CredentialBuffer const credential(raw_credential);
        return credential.get()->CredentialBlobSize > 0;
    }

    std::optional<std::string> CredentialStore::Load(winrt::hstring const& provider)
    {
        auto const target = Target(provider);
        PCREDENTIALW raw_credential = nullptr;
        if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &raw_credential))
        {
            if (GetLastError() == ERROR_NOT_FOUND)
            {
                return std::nullopt;
            }
            throw CredentialError("Windows couldn't read the saved sign-in.");
        }

        CredentialBuffer const credential(raw_credential);
        auto const* bytes = reinterpret_cast<char const*>(credential.get()->CredentialBlob);
        auto const length = credential.get()->CredentialBlobSize;
        if (!bytes || length == 0 || length > CRED_MAX_CREDENTIAL_BLOB_SIZE)
        {
            throw CredentialError("The saved sign-in is invalid.");
        }
        std::string token(bytes, length);
        if (!AccessTokenIsValid(token))
        {
            SecureZeroMemory(token.data(), token.size());
            throw CredentialError("The saved sign-in is invalid.");
        }
        return token;
    }

    void CredentialStore::Save(
        winrt::hstring const& provider,
        winrt::hstring const& access_token)
    {
        auto const target = Target(provider);
        SensitiveBytes const token(winrt::to_string(access_token));
        if (!AccessTokenIsValid(token.get()))
        {
            throw CredentialError("The online service returned an invalid sign-in.");
        }

        CREDENTIALW credential{};
        credential.Type = CRED_TYPE_GENERIC;
        credential.TargetName = const_cast<wchar_t*>(target.c_str());
        credential.CredentialBlobSize = static_cast<DWORD>(token.get().size());
        credential.CredentialBlob = reinterpret_cast<LPBYTE>(
            const_cast<char*>(token.get().data()));
        credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
        credential.UserName = const_cast<wchar_t*>(provider.c_str());
        if (!CredWriteW(&credential, 0))
        {
            throw CredentialError("Windows couldn't save the sign-in.");
        }
    }

    void CredentialStore::Remove(winrt::hstring const& provider) noexcept
    {
        try
        {
            auto const target = Target(provider);
            if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) &&
                GetLastError() != ERROR_NOT_FOUND)
            {
                return;
            }
        }
        catch (...)
        {
        }
    }
}
