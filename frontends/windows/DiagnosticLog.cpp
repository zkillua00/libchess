#include "pch.h"
#include "DiagnosticLog.h"

namespace
{
    constexpr std::uint64_t MaximumLogBytes = 512 * 1024;
    std::mutex LogMutex;

    class FileHandle final
    {
    public:
        explicit FileHandle(HANDLE value) noexcept : value_(value) {}
        ~FileHandle()
        {
            if (value_ != INVALID_HANDLE_VALUE)
            {
                CloseHandle(value_);
            }
        }

        FileHandle(FileHandle const&) = delete;
        FileHandle& operator=(FileHandle const&) = delete;

        HANDLE get() const noexcept
        {
            return value_;
        }

    private:
        HANDLE value_;
    };

    std::wstring LogPath()
    {
        PWSTR local_app_data = nullptr;
        if (FAILED(SHGetKnownFolderPath(
                FOLDERID_LocalAppData,
                KF_FLAG_DEFAULT,
                nullptr,
                &local_app_data)))
        {
            return {};
        }

        std::wstring root(local_app_data);
        CoTaskMemFree(local_app_data);
        auto const app_directory = root + L"\\LibChess";
        auto const log_directory = app_directory + L"\\Logs";
        if (!CreateDirectoryW(app_directory.c_str(), nullptr) &&
            GetLastError() != ERROR_ALREADY_EXISTS)
        {
            return {};
        }
        if (!CreateDirectoryW(log_directory.c_str(), nullptr) &&
            GetLastError() != ERROR_ALREADY_EXISTS)
        {
            return {};
        }
        return log_directory + L"\\libchess.log";
    }

    std::wstring Sanitize(winrt::hstring const& value)
    {
        std::wstring sanitized;
        sanitized.reserve(std::min<std::size_t>(value.size(), 1'024));
        for (auto const character : value)
        {
            if (sanitized.size() == 1'024)
            {
                break;
            }
            sanitized.push_back(
                character == L'\r' || character == L'\n' || character < L' '
                    ? L' '
                    : character);
        }
        return sanitized;
    }

    std::string Utf8(std::wstring const& value)
    {
        if (value.empty())
        {
            return {};
        }
        auto const length = WideCharToMultiByte(
            CP_UTF8,
            WC_ERR_INVALID_CHARS,
            value.data(),
            static_cast<int>(value.size()),
            nullptr,
            0,
            nullptr,
            nullptr);
        if (length <= 0)
        {
            return {};
        }
        std::string result(static_cast<std::size_t>(length), '\0');
        if (WideCharToMultiByte(
                CP_UTF8,
                WC_ERR_INVALID_CHARS,
                value.data(),
                static_cast<int>(value.size()),
                result.data(),
                length,
                nullptr,
                nullptr) != length)
        {
            return {};
        }
        return result;
    }
}

namespace LibChess::Windows
{
    void DiagnosticLog::Write(
        winrt::hstring const& category,
        winrt::hstring const& message) noexcept
    {
        try
        {
            SYSTEMTIME timestamp{};
            GetSystemTime(&timestamp);
            wchar_t prefix[128]{};
            swprintf_s(
                prefix,
                L"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ [%lu:%lu] ",
                timestamp.wYear,
                timestamp.wMonth,
                timestamp.wDay,
                timestamp.wHour,
                timestamp.wMinute,
                timestamp.wSecond,
                timestamp.wMilliseconds,
                GetCurrentProcessId(),
                GetCurrentThreadId());
            auto const line = std::wstring(prefix) + L"[" + Sanitize(category) + L"] " +
                Sanitize(message) + L"\r\n";
            OutputDebugStringW(line.c_str());

            std::scoped_lock const lock(LogMutex);
            auto const path = LogPath();
            if (path.empty())
            {
                return;
            }
            FileHandle const file(CreateFileW(
                path.c_str(),
                GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                nullptr,
                OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                nullptr));
            if (file.get() == INVALID_HANDLE_VALUE)
            {
                return;
            }

            LARGE_INTEGER size{};
            if (GetFileSizeEx(file.get(), &size) &&
                static_cast<std::uint64_t>(size.QuadPart) >= MaximumLogBytes)
            {
                LARGE_INTEGER start{};
                SetFilePointerEx(file.get(), start, nullptr, FILE_BEGIN);
                SetEndOfFile(file.get());
            }
            else
            {
                LARGE_INTEGER end{};
                SetFilePointerEx(file.get(), end, nullptr, FILE_END);
            }

            auto const bytes = Utf8(line);
            DWORD written = 0;
            if (!bytes.empty())
            {
                WriteFile(
                    file.get(),
                    bytes.data(),
                    static_cast<DWORD>(bytes.size()),
                    &written,
                    nullptr);
            }
        }
        catch (...)
        {
        }
    }

    winrt::hstring DiagnosticLog::Path() noexcept
    {
        try
        {
            return winrt::hstring(LogPath());
        }
        catch (...)
        {
            return {};
        }
    }
}
