#pragma once

namespace LibChess::Windows
{
    class DiagnosticLog final
    {
    public:
        static void Write(
            winrt::hstring const& category,
            winrt::hstring const& message) noexcept;
        static winrt::hstring Path() noexcept;
    };
}
