#pragma once
#include <string>

namespace ws {

std::string  WideToUtf8(std::wstring_view w);
std::wstring Utf8ToWide(std::string_view s);

}
