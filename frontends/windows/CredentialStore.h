#pragma once

namespace LibChess::Windows
{
    class CredentialStore final
    {
    public:
        static bool Contains(winrt::hstring const& provider);
        static std::optional<std::string> Load(winrt::hstring const& provider);
        static void Save(winrt::hstring const& provider, winrt::hstring const& access_token);
        static void Remove(winrt::hstring const& provider) noexcept;

    private:
        static std::wstring Target(winrt::hstring const& provider);
    };
}
