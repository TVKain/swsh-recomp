// PokemonSword-Play.exe: starts the game straight away, skipping the start screen (PokemonSword.exe --play next to
// this file, its working folder this folder). A GUI-subsystem program: no console window. Arguments after its own
// name are passed on; the game's exit code is returned. The game itself shows the start screen when its files are not
// set up yet (runtime/main.c).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR args, int show) {
    (void)inst, (void)prev, (void)show;
    wchar_t dir[MAX_PATH], exe[MAX_PATH], cmd[4096];
    DWORD n = GetModuleFileNameW(NULL, dir, MAX_PATH);
    if (!n || n >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(dir, L'\\');
    if (slash) *slash = 0;
    _snwprintf(exe, MAX_PATH, L"%ls\\PokemonSword.exe", dir);
    if (GetFileAttributesW(exe) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxW(NULL, L"PokemonSword.exe was not found next to this program.", L"Pokémon Sword", MB_ICONERROR);
        return 1;
    }
    _snwprintf(cmd, 4096, L"\"%ls\" --play %ls", exe, args ? args : L"");
    STARTUPINFOW si = {sizeof si};
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(exe, cmd, NULL, NULL, TRUE, 0, NULL, dir, &si, &pi)) {
        MessageBoxW(NULL, L"Could not start PokemonSword.exe.", L"Pokémon Sword", MB_ICONERROR);
        return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
