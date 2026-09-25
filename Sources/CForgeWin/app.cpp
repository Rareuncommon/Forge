// Win32 shell of Forge: main window, ribbon, FeatureManager tree, PropertyManager, status
// bar, Modify box and dialogs. Layout and colours follow the macOS design (docs/design):
// ribbon on top, tree on the left, viewport in the middle, PropertyManager on the right.
//
// Common controls v6 (visual styles, TaskDialog) are activated at run time from a manifest
// written to %TEMP%, and comctl32 is loaded dynamically after that, so the executable needs no
// embedded manifest.

#include "fw_internal.h"

#include <commctrl.h>
#include <commdlg.h>
#include <shobjidl.h>
#include <windowsx.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>

// MARK: strings

std::wstring fw_widen(const char *s) {
    if (!s || !*s) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, w.data(), n);
    return w;
}

std::string fw_narrow(const std::wstring &w) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, s.data(), n, nullptr, nullptr);
    return s;
}

std::vector<std::wstring> fw_split(const char *s) {
    std::vector<std::wstring> out;
    std::wstring w = fw_widen(s);
    if (w.empty()) return out;
    size_t start = 0;
    while (true) {
        size_t nl = w.find(L'\n', start);
        out.push_back(w.substr(start, nl == std::wstring::npos ? std::wstring::npos : nl - start));
        if (nl == std::wstring::npos) break;
        start = nl + 1;
    }
    return out;
}

static std::wstring windowText(HWND h) {
    int n = GetWindowTextLengthW(h);
    std::wstring s(n, L'\0');
    if (n > 0) GetWindowTextW(h, s.data(), n + 1);
    return s;
}

// MARK: common controls v6 at run time

typedef BOOL(WINAPI *InitCommonControlsExFn)(const INITCOMMONCONTROLSEX *);
typedef HRESULT(WINAPI *TaskDialogIndirectFn)(const TASKDIALOGCONFIG *, int *, int *, BOOL *);
static TaskDialogIndirectFn taskDialogIndirect = nullptr;

static void enableVisualStyles() {
    static bool done = false;
    if (done) return;
    done = true;
    wchar_t dir[MAX_PATH];
    if (GetTempPathW(MAX_PATH, dir)) {
        std::wstring path = std::wstring(dir) + L"forge-comctl6.manifest";
        const char *manifest =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\n"
            "<dependency><dependentAssembly><assemblyIdentity type=\"win32\" name=\"Microsoft.Windows.Common-Controls\" "
            "version=\"6.0.0.0\" processorArchitecture=\"*\" publicKeyToken=\"6595b64144ccf1df\" language=\"*\"/>"
            "</dependentAssembly></dependency>\n</assembly>\n";
        HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f != INVALID_HANDLE_VALUE) {
            DWORD written = 0;
            WriteFile(f, manifest, (DWORD)strlen(manifest), &written, nullptr);
            CloseHandle(f);
            ACTCTXW ac = {};
            ac.cbSize = sizeof(ac);
            ac.lpSource = path.c_str();
            HANDLE ctx = CreateActCtxW(&ac);
            ULONG_PTR cookie = 0;
            if (ctx != INVALID_HANDLE_VALUE) ActivateActCtx(ctx, &cookie);  // kept for the process lifetime
        }
    }
    if (HMODULE cc = LoadLibraryW(L"comctl32.dll")) {
        if (auto init = (InitCommonControlsExFn)(void *)GetProcAddress(cc, "InitCommonControlsEx")) {
            INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_WIN95_CLASSES | ICC_TAB_CLASSES | ICC_TREEVIEW_CLASSES | ICC_BAR_CLASSES | ICC_STANDARD_CLASSES};
            init(&icc);
        }
        taskDialogIndirect = (TaskDialogIndirectFn)(void *)GetProcAddress(cc, "TaskDialogIndirect");
    }
}

static void enableDpiAwareness() {
    typedef BOOL(WINAPI * SetCtx)(HANDLE);
    if (HMODULE u = GetModuleHandleW(L"user32.dll")) {
        if (auto f = (SetCtx)(void *)GetProcAddress(u, "SetProcessDpiAwarenessContext")) {
            if (f((HANDLE)-4 /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 */)) return;
        }
    }
    SetProcessDPIAware();
}

// MARK: colours (the design's light theme)

static const COLORREF kChrome = RGB(0xE9, 0xE9, 0xEC), kPanel = RGB(0xFB, 0xFB, 0xFC), kText2 = RGB(0x5E, 0x5E, 0x66);
static const COLORREF kText3 = RGB(0x8A, 0x8A, 0x91), kAccent = RGB(0x1F, 0x5F, 0xD6), kAccentSoft = RGB(0xE1, 0xEA, 0xFB);
static const COLORREF kMessage = RGB(0xFF, 0xF4, 0xCE), kWarning = RGB(0xB4, 0x53, 0x09), kError = RGB(0xC8, 0x2E, 0x21), kLine = RGB(0xD5, 0xD5, 0xDA);

// MARK: ids

enum {
    ID_TAB = 10, ID_FILTER = 11, ID_TREE = 12, ID_STATUS = 13,
    ID_RIBBON = 0x1000, ID_RIBBON_ARROW = 0x1800,
    ID_MODIFY_OK = 0x2E00, ID_MODIFY_CANCEL = 0x2E01, ID_MODIFY_EDIT = 0x2E02,
    ID_PANEL_OK = 0x2F00, ID_PANEL_CANCEL = 0x2F01,
    ID_SECTION = 0x3000, ID_CONTROL = 0x4000
};
static int controlID(int index, int part) { return ID_CONTROL + index * 64 + part; }

static const wchar_t *kMainClass = L"ForgeMain", *kRibbonClass = L"ForgeRibbon", *kPanelClass = L"ForgePanel";
static const wchar_t *kContentClass = L"ForgePanelContent", *kViewClass = L"ForgeViewport", *kModifyClass = L"ForgeModify";

static fw_app *appOf(HWND h) { return (fw_app *)GetWindowLongPtrW(h, GWLP_USERDATA); }

static int modifiers() {
    int m = 0;
    if (GetKeyState(VK_SHIFT) & 0x8000) m |= FW_MOD_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000) m |= FW_MOD_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000) m |= FW_MOD_ALT;
    return m;
}

static fw_event event(int kind, int id = 0, int sub = 0) {
    fw_event e = {};
    e.kind = kind;
    e.id = id;
    e.sub = sub;
    e.button = -1;
    return e;
}

// MARK: layout

static const float kTabHeight = 28, kRibbonHeight = 96, kTreeWidth = 250, kPanelWidth = 320, kFilterHeight = 26;

static void layout(fw_app *a) {
    RECT rc;
    GetClientRect(a->hwnd, &rc);
    SendMessageW(a->status, WM_SIZE, 0, 0);
    RECT sr;
    GetWindowRect(a->status, &sr);
    int statusH = sr.bottom - sr.top;
    int w = rc.right, h = rc.bottom - statusH;
    int tabH = a->px(kTabHeight), ribH = a->px(kRibbonHeight), treeW = a->px(kTreeWidth), panelW = a->px(kPanelWidth), filterH = a->px(kFilterHeight);
    int top = tabH + ribH;
    HDWP d = BeginDeferWindowPos(8);
    d = DeferWindowPos(d, a->tab, nullptr, 0, 0, w, tabH, SWP_NOZORDER);
    d = DeferWindowPos(d, a->ribbon, nullptr, 0, tabH, w, ribH, SWP_NOZORDER);
    d = DeferWindowPos(d, a->filter, nullptr, a->px(6), top + a->px(6), treeW - a->px(12), filterH, SWP_NOZORDER);
    d = DeferWindowPos(d, a->tree, nullptr, 0, top + filterH + a->px(12), treeW, std::max(0, h - top - filterH - a->px(12)), SWP_NOZORDER);
    d = DeferWindowPos(d, a->view, nullptr, treeW, top, std::max(1, w - treeW - panelW), std::max(1, h - top), SWP_NOZORDER);
    d = DeferWindowPos(d, a->panel, nullptr, w - panelW, top, panelW, std::max(0, h - top), SWP_NOZORDER);
    EndDeferWindowPos(d);
}

// MARK: ribbon

static SIZE textSize(HWND h, HFONT font, const std::wstring &s) {
    HDC dc = GetDC(h);
    HGDIOBJ old = SelectObject(dc, font);
    SIZE sz = {0, 0};
    GetTextExtentPoint32W(dc, s.c_str(), (int)s.size(), &sz);
    SelectObject(dc, old);
    ReleaseDC(h, dc);
    return sz;
}

/// Break a title into two lines at the space nearest the middle (large buttons).
static std::wstring twoLines(const std::wstring &s) {
    if (s.size() < 10) return s;
    size_t best = std::wstring::npos;
    for (size_t i = 0; i < s.size(); ++i)
        if (s[i] == L' ' && (best == std::wstring::npos || (size_t)abs((int)i - (int)s.size() / 2) < (size_t)abs((int)best - (int)s.size() / 2))) best = i;
    if (best == std::wstring::npos) return s;
    return s.substr(0, best) + L"\n" + s.substr(best + 1);
}

static void addTooltip(fw_app *a, HWND tool, const std::wstring &text) {
    if (!a->tooltip) return;
    TOOLINFOW ti = {};
    ti.cbSize = sizeof(ti);
    ti.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    ti.hwnd = GetParent(tool);
    ti.uId = (UINT_PTR)tool;
    ti.lpszText = (LPWSTR)text.c_str();
    SendMessageW(a->tooltip, TTM_ADDTOOLW, 0, (LPARAM)&ti);
}

static void buildRibbon(fw_app *a) {
    for (HWND h : a->ribbonButtons) DestroyWindow(h);
    for (HWND h : a->ribbonArrows)
        if (h) DestroyWindow(h);
    a->ribbonButtons.clear();
    a->ribbonArrows.clear();
    a->groupRects.clear();
    int x = a->px(8), top = a->px(6), largeW = a->px(74), largeH = a->px(62), smallW = a->px(128), smallH = a->px(21), arrowW = a->px(14);
    int group = -1, groupStart = x, smallRow = 0, smallX = x, smallMaxW = 0;
    auto closeGroup = [&]() {
        if (group < 0) return;
        if (smallRow > 0) {
            x = smallX + smallMaxW + a->px(4);
            smallRow = 0;
        }
        RECT r = {groupStart - a->px(4), 0, x, a->px(kRibbonHeight)};
        a->groupRects.push_back(r);
        x += a->px(10);
    };
    for (size_t i = 0; i < a->items.size(); ++i) {
        const RibbonItem &it = a->items[i];
        if (it.group != group) {
            closeGroup();
            group = it.group;
            groupStart = x;
            smallMaxW = 0;
        }
        DWORD style = WS_CHILD | WS_VISIBLE | BS_PUSHLIKE | BS_CHECKBOX | (it.enabled ? 0 : WS_DISABLED);
        HWND b;
        if (it.large) {
            if (smallRow > 0) {
                x = smallX + smallMaxW + a->px(4);
                smallRow = 0;
                smallMaxW = 0;
            }
            b = CreateWindowExW(0, L"BUTTON", twoLines(it.title).c_str(), style | BS_MULTILINE | BS_CENTER, x, top, largeW, largeH, a->ribbon,
                                (HMENU)(INT_PTR)(ID_RIBBON + i), nullptr, nullptr);
            x += largeW;
            HWND arrow = nullptr;
            if (!it.variants.empty()) {
                arrow = CreateWindowExW(0, L"BUTTON", L"▾", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | (it.enabled ? 0 : WS_DISABLED), x, top, arrowW,
                                        largeH, a->ribbon, (HMENU)(INT_PTR)(ID_RIBBON_ARROW + i), nullptr, nullptr);
                SendMessageW(arrow, WM_SETFONT, (WPARAM)a->smallFont, TRUE);
                x += arrowW;
            }
            a->ribbonArrows.push_back(arrow);
            x += a->px(2);
        } else {
            if (smallRow == 0) {
                smallX = x;
                smallMaxW = 0;
            }
            int w = std::min(smallW, (int)textSize(a->ribbon, a->font, it.title).cx + a->px(18));
            int y = top + smallRow * (smallH + a->px(1));
            b = CreateWindowExW(0, L"BUTTON", it.title.c_str(), style | BS_LEFT, smallX, y, w, smallH, a->ribbon, (HMENU)(INT_PTR)(ID_RIBBON + i), nullptr,
                                nullptr);
            HWND arrow = nullptr;
            if (!it.variants.empty()) {
                arrow = CreateWindowExW(0, L"BUTTON", L"▾", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | (it.enabled ? 0 : WS_DISABLED), smallX + w, y, arrowW,
                                        smallH, a->ribbon, (HMENU)(INT_PTR)(ID_RIBBON_ARROW + i), nullptr, nullptr);
                SendMessageW(arrow, WM_SETFONT, (WPARAM)a->smallFont, TRUE);
                w += arrowW;
            }
            a->ribbonArrows.push_back(arrow);
            smallMaxW = std::max(smallMaxW, w);
            if (++smallRow == 3) {
                x = smallX + smallMaxW + a->px(4);
                smallRow = 0;
            }
        }
        SendMessageW(b, WM_SETFONT, (WPARAM)a->font, TRUE);
        SendMessageW(b, BM_SETCHECK, it.active ? BST_CHECKED : BST_UNCHECKED, 0);
        addTooltip(a, b, it.help);
        a->ribbonButtons.push_back(b);
    }
    closeGroup();
    InvalidateRect(a->ribbon, nullptr, TRUE);
}

static LRESULT CALLBACK ribbonProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    fw_app *a = appOf(h);
    switch (msg) {
    case WM_COMMAND: {
        if (!a) break;
        int id = LOWORD(wp);
        if (id >= ID_RIBBON_ARROW && id < ID_RIBBON_ARROW + 0x800) {
            size_t i = id - ID_RIBBON_ARROW;
            if (i >= a->items.size()) break;
            HMENU m = CreatePopupMenu();
            for (size_t k = 0; k < a->items[i].variants.size(); ++k) AppendMenuW(m, MF_STRING, k + 1, a->items[i].variants[k].c_str());
            RECT r;
            GetWindowRect((HWND)lp, &r);
            int pick = TrackPopupMenu(m, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN, r.left, r.bottom, 0, h, nullptr);
            DestroyMenu(m);
            if (pick > 0) a->emit(event(FW_EV_RIBBON, (int)i, pick - 1));
        } else if (id >= ID_RIBBON && id < ID_RIBBON + 0x800) {
            a->emit(event(FW_EV_RIBBON, id - ID_RIBBON, -1));
        }
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT rc;
        GetClientRect(h, &rc);
        FillRect(dc, &rc, a ? a->ribbonBrush : (HBRUSH)(COLOR_BTNFACE + 1));
        if (a) {
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, kText2);
            HGDIOBJ old = SelectObject(dc, a->smallFont);
            HPEN pen = CreatePen(PS_SOLID, 1, kLine);
            HGDIOBJ oldPen = SelectObject(dc, pen);
            for (size_t g = 0; g < a->groupRects.size() && g < a->groups.size(); ++g) {
                RECT r = a->groupRects[g];
                RECT label = {r.left, rc.bottom - a->px(18), r.right, rc.bottom - a->px(3)};
                DrawTextW(dc, a->groups[g].c_str(), -1, &label, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
                MoveToEx(dc, r.right + a->px(4), a->px(8), nullptr);
                LineTo(dc, r.right + a->px(4), rc.bottom - a->px(8));
            }
            MoveToEx(dc, 0, rc.bottom - 1, nullptr);
            LineTo(dc, rc.right, rc.bottom - 1);
            SelectObject(dc, oldPen);
            DeleteObject(pen);
            SelectObject(dc, old);
        }
        EndPaint(h, &ps);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_CTLCOLORBTN:
        return a ? (LRESULT)a->ribbonBrush : 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

// MARK: tree

static void buildTree(fw_app *a) {
    a->building = true;
    SendMessageW(a->tree, WM_SETREDRAW, FALSE, 0);
    SendMessageW(a->tree, TVM_DELETEITEM, 0, (LPARAM)TVI_ROOT);
    std::vector<HTREEITEM> parents;
    std::vector<HTREEITEM> withChildren;
    for (size_t i = 0; i < a->nodes.size(); ++i) {
        const TreeItem &n = a->nodes[i];
        int depth = std::max(0, std::min(n.depth, (int)parents.size()));
        parents.resize(depth);
        TVINSERTSTRUCTW ins = {};
        ins.hParent = depth == 0 ? TVI_ROOT : parents.back();
        ins.hInsertAfter = TVI_LAST;
        ins.item.mask = TVIF_TEXT | TVIF_PARAM | TVIF_STATE;
        std::wstring title = n.state == FW_NODE_ROLLBACK_BAR ? L"Rollback" : n.title;
        ins.item.pszText = (LPWSTR)title.c_str();
        ins.item.lParam = (LPARAM)i;
        ins.item.stateMask = TVIS_BOLD;
        ins.item.state = n.selected ? TVIS_BOLD : 0;
        HTREEITEM item = (HTREEITEM)SendMessageW(a->tree, TVM_INSERTITEMW, 0, (LPARAM)&ins);
        if (depth > 0) withChildren.push_back(parents.back());
        parents.push_back(item);
    }
    for (HTREEITEM h : withChildren) SendMessageW(a->tree, TVM_EXPAND, TVE_EXPAND, (LPARAM)h);
    SendMessageW(a->tree, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(a->tree, nullptr, TRUE);
    a->building = false;
}

/// The node under the cursor (for clicks), or -1.
static int treeHit(fw_app *a, bool *onButton) {
    TVHITTESTINFO hit = {};
    DWORD pos = GetMessagePos();
    hit.pt.x = GET_X_LPARAM(pos);
    hit.pt.y = GET_Y_LPARAM(pos);
    ScreenToClient(a->tree, &hit.pt);
    HTREEITEM item = (HTREEITEM)SendMessageW(a->tree, TVM_HITTEST, 0, (LPARAM)&hit);
    if (onButton) *onButton = (hit.flags & TVHT_ONITEMBUTTON) != 0;
    if (!item || !(hit.flags & (TVHT_ONITEM | TVHT_ONITEMRIGHT | TVHT_ONITEMINDENT))) return -1;
    TVITEMW it = {};
    it.mask = TVIF_PARAM;
    it.hItem = item;
    SendMessageW(a->tree, TVM_GETITEMW, 0, (LPARAM)&it);
    return (int)it.lParam;
}

static LRESULT treeNotify(fw_app *a, NMHDR *nm) {
    switch (nm->code) {
    case TVN_SELCHANGINGW:
    case TVN_SELCHANGINGA:
        return TRUE;  // the model's selection is shown (bold, custom draw), not the control's
    case NM_CLICK: {
        bool onButton = false;
        int i = treeHit(a, &onButton);
        if (i >= 0 && !onButton) {
            fw_event e = event(FW_EV_TREE_SELECT, i);
            e.mods = modifiers();
            a->emit(e);
        }
        return 0;
    }
    case NM_DBLCLK: {
        int i = treeHit(a, nullptr);
        if (i >= 0) a->emit(event(FW_EV_TREE_ACTIVATE, i));
        return TRUE;
    }
    case NM_RCLICK: {
        int i = treeHit(a, nullptr);
        if (i < 0 || i >= (int)a->nodes.size() || a->nodes[i].menu.empty()) return TRUE;
        HMENU m = CreatePopupMenu();
        for (size_t k = 0; k < a->nodes[i].menu.size(); ++k) {
            const std::wstring &t = a->nodes[i].menu[k];
            if (t == L"Delete" || t == L"What's Wrong?") AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
            AppendMenuW(m, MF_STRING, k + 1, t.c_str());
        }
        DWORD pos = GetMessagePos();
        int pick = TrackPopupMenu(m, TPM_RETURNCMD, GET_X_LPARAM(pos), GET_Y_LPARAM(pos), 0, a->hwnd, nullptr);
        DestroyMenu(m);
        if (pick > 0) a->emit(event(FW_EV_TREE_MENU, i, pick - 1));
        return TRUE;
    }
    case TVN_GETINFOTIPW: {
        auto *tip = (NMTVGETINFOTIPW *)nm;
        size_t i = (size_t)tip->lParam;
        if (i < a->nodes.size() && !a->nodes[i].tooltip.empty()) lstrcpynW(tip->pszText, a->nodes[i].tooltip.c_str(), tip->cchTextMax);
        return 0;
    }
    case NM_CUSTOMDRAW: {
        auto *cd = (NMTVCUSTOMDRAW *)nm;
        if (cd->nmcd.dwDrawStage == CDDS_PREPAINT) return CDRF_NOTIFYITEMDRAW;
        if (cd->nmcd.dwDrawStage == CDDS_ITEMPREPAINT) {
            size_t i = (size_t)cd->nmcd.lItemlParam;
            if (i < a->nodes.size()) {
                const TreeItem &n = a->nodes[i];
                cd->clrTextBk = n.selected ? kAccentSoft : kPanel;
                switch (n.state) {
                case FW_NODE_SUPPRESSED:
                case FW_NODE_ROLLED_BACK: cd->clrText = kText3; break;
                case FW_NODE_WARNING: cd->clrText = kWarning; break;
                case FW_NODE_ERROR: cd->clrText = kError; break;
                case FW_NODE_ROLLBACK_BAR: cd->clrText = kAccent; return CDRF_NOTIFYPOSTPAINT;
                default: cd->clrText = n.selected ? RGB(0x1A, 0x4F, 0xB3) : RGB(0x1D, 0x1D, 0x1F);
                }
            }
            return CDRF_DODEFAULT;
        }
        if (cd->nmcd.dwDrawStage == CDDS_ITEMPOSTPAINT) {
            // The rollback bar: a thick accent line after its label, as in SolidWorks.
            RECT text = {};
            *(HTREEITEM *)&text = (HTREEITEM)cd->nmcd.dwItemSpec;
            SendMessageW(a->tree, TVM_GETITEMRECT, TRUE, (LPARAM)&text);
            RECT bar = {text.right + a->px(6), (cd->nmcd.rc.top + cd->nmcd.rc.bottom) / 2 - a->px(1), cd->nmcd.rc.right - a->px(8),
                        (cd->nmcd.rc.top + cd->nmcd.rc.bottom) / 2 + a->px(2)};
            HBRUSH b = CreateSolidBrush(kAccent);
            FillRect(cd->nmcd.hdc, &bar, b);
            DeleteObject(b);
        }
        return CDRF_DODEFAULT;
    }
    }
    return 0;
}

// MARK: PropertyManager

static WNDPROC editProc = nullptr;

/// Fields: Return submits, like leaving the field.
static LRESULT CALLBACK fieldProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_KEYDOWN && wp == VK_RETURN) {
        HWND content = GetParent(h);
        SendMessageW(content, WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(h), 0xF00D), (LPARAM)h);
        return 0;
    }
    if (msg == WM_CHAR && wp == VK_RETURN) return 0;
    return CallWindowProcW(editProc, h, msg, wp, lp);
}

static int textHeight(fw_app *a, HFONT font, const std::wstring &s, int width) {
    HDC dc = GetDC(a->content);
    HGDIOBJ old = SelectObject(dc, font);
    RECT r = {0, 0, width, 0};
    DrawTextW(dc, s.c_str(), -1, &r, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, old);
    ReleaseDC(a->content, dc);
    return r.bottom;
}

static HWND make(fw_app *a, const wchar_t *cls, const std::wstring &text, DWORD style, int x, int y, int w, int h, int id, HFONT font, DWORD ex = 0) {
    HWND c = CreateWindowExW(ex, cls, text.c_str(), WS_CHILD | WS_VISIBLE | style, x, y, w, h, a->content, (HMENU)(INT_PTR)id, nullptr, nullptr);
    SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
    return c;
}

static void updateScroll(fw_app *a) {
    RECT rc;
    GetClientRect(a->panel, &rc);
    int page = rc.bottom;
    a->scroll = std::max(0, std::min(a->scroll, std::max(0, a->contentHeight - page)));
    SCROLLINFO si = {sizeof(si), SIF_RANGE | SIF_PAGE | SIF_POS, 0, std::max(0, a->contentHeight - 1), (UINT)page, a->scroll, 0};
    SetScrollInfo(a->panel, SB_VERT, &si, TRUE);
    SetWindowPos(a->content, nullptr, 0, -a->scroll, rc.right, std::max(a->contentHeight, (int)rc.bottom), SWP_NOZORDER);
}

/// Create the native controls of the page (after fw_panel_end and when the width changes).
static void buildPanel(fw_app *a) {
    a->building = true;
    SendMessageW(a->content, WM_SETREDRAW, FALSE, 0);
    HWND child = GetWindow(a->content, GW_CHILD);
    while (child) {
        HWND next = GetWindow(child, GW_HWNDNEXT);
        DestroyWindow(child);
        child = next;
    }
    a->panelChrome.clear();
    a->messageHwnd = nullptr;
    for (auto &c : a->controls) {
        c.main = nullptr;
        c.extra.clear();
    }
    for (auto &s : a->sections) s.hwnd = nullptr;

    RECT rc;
    GetClientRect(a->panel, &rc);
    int W = rc.right - a->px(2), pad = a->px(14), inner = W - 2 * pad;
    int y = a->px(12), rowH = a->px(24), gap = a->px(6);
    int labelW = a->px(118), fieldW = inner - labelW - a->px(46);

    // Header: title, subtitle, OK / Cancel.
    int buttonsW = (a->pOK ? a->px(46) : 0) + (a->pCancel ? a->px(64) : 0);
    a->panelChrome.push_back(make(a, L"STATIC", a->pTitle, SS_LEFT | SS_NOPREFIX | SS_ENDELLIPSIS, pad, y, inner - buttonsW, a->px(22), 0, a->big));
    int bx = pad + inner - buttonsW;
    if (a->pOK) {
        a->panelChrome.push_back(make(a, L"BUTTON", L"OK", BS_DEFPUSHBUTTON, bx, y, a->px(42), a->px(26), ID_PANEL_OK, a->bold));
        bx += a->px(46);
    }
    if (a->pCancel) a->panelChrome.push_back(make(a, L"BUTTON", L"Cancel", BS_PUSHBUTTON, bx, y, a->px(60), a->px(26), ID_PANEL_CANCEL, a->font));
    y += a->px(24);
    if (!a->pSubtitle.empty()) {
        a->panelChrome.push_back(make(a, L"STATIC", a->pSubtitle, SS_LEFT | SS_NOPREFIX | SS_ENDELLIPSIS, pad, y, inner, a->px(18), 0, a->smallFont));
        y += a->px(20);
    }
    y += a->px(6);
    if (!a->pMessage.empty()) {
        int h = textHeight(a, a->font, a->pMessage, inner - a->px(16)) + a->px(16);
        a->messageHwnd = make(a, L"STATIC", a->pMessage, SS_LEFT | SS_NOPREFIX, pad, y, inner, h, 0, a->font);
        a->panelChrome.push_back(a->messageHwnd);
        y += h + a->px(10);
    }

    int section = -1;
    bool sectionOn = true;
    for (size_t i = 0; i < a->controls.size(); ++i) {
        PanelControl &c = a->controls[i];
        while (section < c.section) {
            ++section;
            PanelSection &s = a->sections[section];
            y += a->px(6);
            if (s.toggle >= 0) {
                s.hwnd = make(a, L"BUTTON", s.title, BS_AUTOCHECKBOX, pad, y, inner, rowH, ID_SECTION + section, a->bold);
                SendMessageW(s.hwnd, BM_SETCHECK, s.toggle ? BST_CHECKED : BST_UNCHECKED, 0);
                sectionOn = s.toggle == 1;
                y += rowH + a->px(2);
            } else {
                sectionOn = true;
                if (!s.title.empty()) {
                    s.hwnd = make(a, L"STATIC", s.title, SS_LEFT | SS_NOPREFIX, pad, y, inner, a->px(20), 0, a->bold);
                    y += a->px(22);
                }
            }
        }
        if (!sectionOn) continue;
        int x = pad + a->px(6), w = inner - a->px(6);
        switch (c.kind) {
        case PK_FIELD: {
            c.extra.push_back(make(a, L"STATIC", c.label, SS_LEFT | SS_NOPREFIX | SS_CENTERIMAGE, x, y, labelW, rowH, 0, a->font));
            c.main = make(a, L"EDIT", c.value, ES_AUTOHSCROLL | WS_TABSTOP, x + labelW, y, fieldW, rowH, controlID((int)i, 0), a->font, WS_EX_CLIENTEDGE);
            WNDPROC old = (WNDPROC)SetWindowLongPtrW(c.main, GWLP_WNDPROC, (LONG_PTR)fieldProc);
            if (!editProc) editProc = old;
            if (!c.unit.empty()) c.extra.push_back(make(a, L"STATIC", c.unit, SS_LEFT | SS_NOPREFIX | SS_CENTERIMAGE, x + labelW + fieldW + a->px(6), y, a->px(40), rowH, 0, a->smallFont));
            y += rowH + gap;
            break;
        }
        case PK_CHECK:
            c.main = make(a, L"BUTTON", c.label, BS_AUTOCHECKBOX | WS_TABSTOP, x, y, w, rowH, controlID((int)i, 0), a->font);
            SendMessageW(c.main, BM_SETCHECK, c.on ? BST_CHECKED : BST_UNCHECKED, 0);
            y += rowH + a->px(2);
            break;
        case PK_CHOICE: {
            c.extra.push_back(make(a, L"STATIC", c.label, SS_LEFT | SS_NOPREFIX | SS_CENTERIMAGE, x, y, labelW, rowH, 0, a->font));
            c.main = make(a, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, x + labelW, y, fieldW + a->px(40), a->px(240), controlID((int)i, 0), a->font);
            for (auto &o : c.options) SendMessageW(c.main, CB_ADDSTRING, 0, (LPARAM)o.c_str());
            SendMessageW(c.main, CB_SETCURSEL, c.selected, 0);
            y += rowH + gap;
            break;
        }
        case PK_LIST: {
            int n = std::max(1, (int)c.items.size());
            int h = std::min(n, 8) * a->px(17) + a->px(8);
            c.main = make(a, L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL, x, y, w, h, controlID((int)i, 0), a->font, WS_EX_CLIENTEDGE);
            if (c.items.empty()) {
                SendMessageW(c.main, LB_ADDSTRING, 0, (LPARAM)c.placeholder.c_str());
            } else {
                for (auto &it : c.items) SendMessageW(c.main, LB_ADDSTRING, 0, (LPARAM)it.c_str());
            }
            y += h + gap;
            break;
        }
        case PK_NOTE: {
            int h = textHeight(a, a->smallFont, c.label, w);
            c.main = make(a, L"STATIC", c.label, SS_LEFT | SS_NOPREFIX, x, y, w, h, controlID((int)i, 0), a->smallFont);
            y += h + gap;
            break;
        }
        case PK_VALUE:
            c.extra.push_back(make(a, L"STATIC", c.label, SS_LEFT | SS_NOPREFIX | SS_CENTERIMAGE, x, y, labelW, a->px(20), 0, a->font));
            c.main = make(a, L"STATIC", c.value, SS_LEFT | SS_NOPREFIX | SS_CENTERIMAGE | SS_ENDELLIPSIS, x + labelW, y, w - labelW, a->px(20), controlID((int)i, 0), a->font);
            y += a->px(22);
            break;
        case PK_BUTTONS: {
            int bxx = x;
            for (size_t k = 0; k < c.items.size(); ++k) {
                int bw = (int)textSize(a->content, a->font, c.items[k]).cx + a->px(18);
                if (bxx > x && bxx + bw > x + w) {
                    bxx = x;
                    y += rowH + a->px(4);
                }
                HWND b = make(a, L"BUTTON", c.items[k], BS_PUSHBUTTON | WS_TABSTOP, bxx, y, bw, rowH, controlID((int)i, (int)k + 1), a->font);
                if (k == 0) c.main = b; else c.extra.push_back(b);
                bxx += bw + a->px(4);
            }
            y += rowH + gap;
            break;
        }
        case PK_ROWS:
            for (size_t k = 0; k < c.items.size() && k < 63; ++k) {
                bool bad = k < c.problems.size() && c.problems[k];
                int tw = w - (c.deletable ? a->px(26) : 0);
                HWND t = make(a, L"STATIC", c.items[k], SS_LEFT | SS_NOPREFIX | SS_ENDELLIPSIS, x, y, tw, a->px(18), controlID((int)i, 0), a->font);
                SetPropW(t, L"ForgeProblem", (HANDLE)(INT_PTR)(bad ? 1 : 0));
                c.extra.push_back(t);
                if (c.deletable) c.extra.push_back(make(a, L"BUTTON", L"✕", BS_PUSHBUTTON, x + tw + a->px(4), y, a->px(22), a->px(20), controlID((int)i, (int)k + 1), a->smallFont));
                y += a->px(18);
                if (k < c.details.size() && !c.details[k].empty()) {
                    c.extra.push_back(make(a, L"STATIC", c.details[k], SS_LEFT | SS_NOPREFIX | SS_ENDELLIPSIS, x + a->px(10), y, tw - a->px(10), a->px(16), 0, a->smallFont));
                    y += a->px(17);
                }
                y += a->px(4);
            }
            y += gap;
            break;
        }
    }
    a->contentHeight = y + a->px(20);
    SendMessageW(a->content, WM_SETREDRAW, TRUE, 0);
    updateScroll(a);
    RedrawWindow(a->content, nullptr, nullptr, RDW_ERASE | RDW_INVALIDATE | RDW_ALLCHILDREN);
    a->building = false;
}

static LRESULT CALLBACK contentProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    fw_app *a = appOf(h);
    if (!a) return DefWindowProcW(h, msg, wp, lp);
    switch (msg) {
    case WM_COMMAND: {
        int id = LOWORD(wp), code = HIWORD(wp);
        if (id == ID_PANEL_OK) {
            a->emit(event(FW_EV_PANEL_OK));
            return 0;
        }
        if (id == ID_PANEL_CANCEL) {
            a->emit(event(FW_EV_PANEL_CANCEL));
            return 0;
        }
        if (a->building) return 0;
        if (id >= ID_SECTION && id < ID_CONTROL) {
            int s = id - ID_SECTION;
            a->emit(event(FW_EV_PANEL_SECTION, s, SendMessageW((HWND)lp, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0));
            return 0;
        }
        if (id < ID_CONTROL) return 0;
        int index = (id - ID_CONTROL) / 64, part = (id - ID_CONTROL) % 64;
        if (index >= (int)a->controls.size()) return 0;
        PanelControl &c = a->controls[index];
        switch (c.kind) {
        case PK_FIELD:
            if (code == EN_CHANGE) {
                std::string t = fw_narrow(windowText((HWND)lp));
                fw_event e = event(FW_EV_PANEL_TEXT, index);
                e.text = t.c_str();
                a->emit(e);
            } else if (code == EN_KILLFOCUS || code == 0xF00D) {
                a->emit(event(FW_EV_PANEL_SUBMIT, index));
            }
            break;
        case PK_CHECK:
            if (code == BN_CLICKED) a->emit(event(FW_EV_PANEL_CHECK, index, SendMessageW((HWND)lp, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0));
            break;
        case PK_CHOICE:
            if (code == CBN_SELCHANGE) a->emit(event(FW_EV_PANEL_CHOICE, index, (int)SendMessageW((HWND)lp, CB_GETCURSEL, 0, 0)));
            break;
        case PK_LIST:
            if (code == LBN_SETFOCUS || code == LBN_SELCHANGE) a->emit(event(FW_EV_PANEL_LIST, index));
            break;
        case PK_BUTTONS:
            if (code == BN_CLICKED && part > 0) a->emit(event(FW_EV_PANEL_BUTTON, index, part - 1));
            break;
        case PK_ROWS:
            if (code == BN_CLICKED && part > 0) a->emit(event(FW_EV_PANEL_ROW_DELETE, index, part - 1));
            break;
        default:
            break;
        }
        return 0;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)wp;
        HWND c = (HWND)lp;
        SetBkMode(dc, TRANSPARENT);
        if (c == a->messageHwnd) {
            SetTextColor(dc, RGB(0x5C, 0x45, 0x00));
            return (LRESULT)a->messageBrush;
        }
        SetTextColor(dc, RGB(0x1D, 0x1D, 0x1F));
        int id = GetDlgCtrlID(c);
        if (id >= ID_CONTROL) {
            int index = (id - ID_CONTROL) / 64;
            if (index < (int)a->controls.size()) {
                const PanelControl &pc = a->controls[index];
                if (pc.kind == PK_NOTE) SetTextColor(dc, pc.warning ? kWarning : kText2);
                if (pc.kind == PK_ROWS && GetPropW(c, L"ForgeProblem")) SetTextColor(dc, kError);
            }
        } else if (c != a->panelChrome.front()) {
            if (GetWindowLongPtrW(c, GWL_STYLE) & SS_ENDELLIPSIS && std::find(a->panelChrome.begin(), a->panelChrome.end(), c) != a->panelChrome.end())
                SetTextColor(dc, kText2);
        }
        return (LRESULT)a->panelBrush;
    }
    case WM_CTLCOLORBTN:
        return (LRESULT)a->panelBrush;
    case WM_CTLCOLORLISTBOX: {
        HWND c = (HWND)lp;
        int id = GetDlgCtrlID(c);
        int index = id >= ID_CONTROL ? (id - ID_CONTROL) / 64 : -1;
        if (index >= 0 && index < (int)a->controls.size() && a->controls[index].active) {
            SetBkColor((HDC)wp, kAccentSoft);
            return (LRESULT)a->activeBrush;
        }
        return (LRESULT)a->fieldBrush;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT rc;
        GetClientRect(h, &rc);
        FillRect(dc, &rc, a->panelBrush);
        if (a->messageHwnd) {
            RECT m;
            GetWindowRect(a->messageHwnd, &m);
            MapWindowPoints(nullptr, h, (POINT *)&m, 2);
            InflateRect(&m, 1, 1);
            HBRUSH border = CreateSolidBrush(RGB(0xE8, 0xC9, 0x5A));
            FrameRect(dc, &m, border);
            DeleteObject(border);
        }
        EndPaint(h, &ps);
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static LRESULT CALLBACK panelProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    fw_app *a = appOf(h);
    if (!a) return DefWindowProcW(h, msg, wp, lp);
    switch (msg) {
    case WM_SIZE: {
        static int lastWidth = -1;
        if (LOWORD(lp) != lastWidth) {
            lastWidth = LOWORD(lp);
            buildPanel(a);
        } else {
            updateScroll(a);
        }
        return 0;
    }
    case WM_VSCROLL: {
        RECT rc;
        GetClientRect(h, &rc);
        int line = a->px(24);
        switch (LOWORD(wp)) {
        case SB_LINEUP: a->scroll -= line; break;
        case SB_LINEDOWN: a->scroll += line; break;
        case SB_PAGEUP: a->scroll -= rc.bottom; break;
        case SB_PAGEDOWN: a->scroll += rc.bottom; break;
        case SB_THUMBTRACK:
        case SB_THUMBPOSITION: {
            SCROLLINFO si = {sizeof(si), SIF_TRACKPOS};
            GetScrollInfo(h, SB_VERT, &si);
            a->scroll = si.nTrackPos;
            break;
        }
        }
        updateScroll(a);
        return 0;
    }
    case WM_MOUSEWHEEL:
        a->scroll -= GET_WHEEL_DELTA_WPARAM(wp) * a->px(24) * 3 / WHEEL_DELTA;
        updateScroll(a);
        return 0;
    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(h, &rc);
        FillRect((HDC)wp, &rc, a->panelBrush);
        return 1;
    }
    }
    return DefWindowProcW(h, msg, wp, lp);
}

// MARK: viewport window

static const char *keyName(WPARAM vk) {
    switch (vk) {
    case VK_RETURN: return "return";
    case VK_ESCAPE: return "escape";
    case VK_DELETE:
    case VK_BACK: return "delete";
    case VK_SPACE: return "space";
    default: return nullptr;
    }
}

static LRESULT CALLBACK viewProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    fw_app *a = appOf(h);
    if (!a) return DefWindowProcW(h, msg, wp, lp);
    auto mouse = [&](int kind, int button) {
        fw_event e = event(kind);
        e.x = GET_X_LPARAM(lp);
        e.y = GET_Y_LPARAM(lp);
        e.button = button;
        e.mods = modifiers();
        e.clicks = 1;
        return e;
    };
    switch (msg) {
    case WM_PAINT: {
        ValidateRect(h, nullptr);
        a->emit(event(FW_EV_PAINT));
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_SIZE: {
        if (a->renderer) fw_renderer_resize(a->renderer, LOWORD(lp), HIWORD(lp));
        fw_event e = event(FW_EV_RESIZE);
        e.x = LOWORD(lp);
        e.y = HIWORD(lp);
        a->emit(e);
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDBLCLK:
    case WM_MBUTTONDBLCLK: {
        SetFocus(h);
        SetCapture(h);
        int button = (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONDBLCLK) ? 0 : (msg == WM_RBUTTONDOWN || msg == WM_RBUTTONDBLCLK) ? 1 : 2;
        fw_event e = mouse(FW_EV_MOUSE_DOWN, button);
        e.clicks = (msg == WM_LBUTTONDBLCLK || msg == WM_RBUTTONDBLCLK || msg == WM_MBUTTONDBLCLK) ? 2 : 1;
        a->emit(e);
        return 0;
    }
    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_MBUTTONUP: {
        if (!(wp & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON))) ReleaseCapture();
        a->emit(mouse(FW_EV_MOUSE_UP, msg == WM_LBUTTONUP ? 0 : msg == WM_RBUTTONUP ? 1 : 2));
        return 0;
    }
    case WM_MOUSEMOVE: {
        TRACKMOUSEEVENT t = {sizeof(t), TME_LEAVE, h, 0};
        TrackMouseEvent(&t);
        int button = (wp & MK_LBUTTON) ? 0 : (wp & MK_RBUTTON) ? 1 : (wp & MK_MBUTTON) ? 2 : -1;
        a->emit(mouse(FW_EV_MOUSE_MOVE, button));
        return 0;
    }
    case WM_MOUSELEAVE:
        a->emit(event(FW_EV_MOUSE_LEAVE));
        return 0;
    case WM_MOUSEWHEEL: {
        POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        ScreenToClient(h, &p);
        fw_event e = event(FW_EV_MOUSE_WHEEL);
        e.x = p.x;
        e.y = p.y;
        e.wheel = (float)GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
        e.mods = modifiers();
        a->emit(e);
        return 0;
    }
    case WM_CONTEXTMENU:
        return 0;  // right button pans the view
    case WM_KEYDOWN: {
        const char *k = keyName(wp);
        if (k) {
            fw_event e = event(FW_EV_KEY);
            e.text = k;
            e.mods = modifiers();
            a->emit(e);
            return 0;
        }
        break;
    }
    case WM_CHAR: {
        if (wp < 32 || (GetKeyState(VK_CONTROL) & 0x8000)) return 0;
        wchar_t w[2] = {(wchar_t)wp, 0};
        std::string t = fw_narrow(w);
        fw_event e = event(FW_EV_KEY);
        e.text = t.c_str();
        e.mods = modifiers();
        a->emit(e);
        return 0;
    }
    case WM_GETDLGCODE:
        return DLGC_WANTALLKEYS;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

// MARK: Modify box

static WNDPROC modifyEditProc = nullptr;

static void commitModify(fw_app *a) {
    std::string t = fw_narrow(windowText(a->modifyEdit));
    fw_event e = event(FW_EV_EDIT_COMMIT);
    e.text = t.c_str();
    a->emit(e);
}

static LRESULT CALLBACK modifyFieldProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    fw_app *a = appOf(GetParent(h));
    if (a && msg == WM_KEYDOWN && wp == VK_RETURN) {
        commitModify(a);
        return 0;
    }
    if (a && msg == WM_KEYDOWN && wp == VK_ESCAPE) {
        a->emit(event(FW_EV_EDIT_CANCEL));
        return 0;
    }
    if (msg == WM_CHAR && (wp == VK_RETURN || wp == VK_ESCAPE)) return 0;
    return CallWindowProcW(modifyEditProc, h, msg, wp, lp);
}

static LRESULT CALLBACK modifyProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    fw_app *a = appOf(h);
    if (!a) return DefWindowProcW(h, msg, wp, lp);
    switch (msg) {
    case WM_COMMAND:
        if (LOWORD(wp) == ID_MODIFY_OK) commitModify(a);
        if (LOWORD(wp) == ID_MODIFY_CANCEL) a->emit(event(FW_EV_EDIT_CANCEL));
        return 0;
    case WM_CTLCOLORSTATIC:
        SetBkMode((HDC)wp, TRANSPARENT);
        SetTextColor((HDC)wp, kText2);
        return (LRESULT)a->panelBrush;
    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(h, &rc);
        FillRect((HDC)wp, &rc, a->panelBrush);
        HBRUSH border = CreateSolidBrush(kLine);
        FrameRect((HDC)wp, &rc, border);
        DeleteObject(border);
        return 1;
    }
    }
    return DefWindowProcW(h, msg, wp, lp);
}

// MARK: main window

static void buildMenu(fw_app *a) {
    HMENU bar = CreateMenu();
    HMENU file = CreatePopupMenu(), edit = CreatePopupMenu(), view = CreatePopupMenu(), help = CreatePopupMenu(), orient = CreatePopupMenu(),
          display = CreatePopupMenu();
    AppendMenuW(file, MF_STRING, FW_MENU_NEW, L"&New Part\tCtrl+N");
    AppendMenuW(file, MF_STRING, FW_MENU_OPEN, L"&Open…\tCtrl+O");
    AppendMenuW(file, MF_STRING, FW_MENU_SAVE, L"&Save\tCtrl+S");
    AppendMenuW(file, MF_STRING, FW_MENU_SAVE_AS, L"Save &As…\tCtrl+Shift+S");
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, FW_MENU_EXPORT_STEP, L"Export &STEP…");
    AppendMenuW(file, MF_STRING, FW_MENU_EXPORT_STL, L"Export ST&L…");
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, FW_MENU_EXIT, L"E&xit");
    AppendMenuW(edit, MF_STRING, FW_MENU_UNDO, L"&Undo\tCtrl+Z");
    AppendMenuW(edit, MF_STRING, FW_MENU_REDO, L"&Redo\tCtrl+Y");
    const wchar_t *names[] = {L"&Front\tCtrl+1", L"&Back\tCtrl+2", L"&Left\tCtrl+3", L"&Right\tCtrl+4", L"&Top\tCtrl+5", L"B&ottom\tCtrl+6",
                              L"&Isometric\tCtrl+7", L"&Dimetric", L"T&rimetric", L"&Normal To\tCtrl+8"};
    for (int i = 0; i < 10; ++i) AppendMenuW(orient, MF_STRING, FW_MENU_FRONT + i, names[i]);
    AppendMenuW(view, MF_POPUP, (UINT_PTR)orient, L"&Orientation");
    AppendMenuW(view, MF_STRING, FW_MENU_FIT, L"Zoom to &Fit\tF");
    AppendMenuW(view, MF_STRING, FW_MENU_PREVIOUS, L"&Previous View");
    AppendMenuW(view, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(display, MF_STRING, FW_MENU_SHADED_EDGES, L"Shaded With &Edges");
    AppendMenuW(display, MF_STRING, FW_MENU_SHADED, L"&Shaded");
    AppendMenuW(display, MF_STRING, FW_MENU_WIREFRAME, L"&Wireframe");
    AppendMenuW(display, MF_STRING, FW_MENU_HIDDEN_LINES, L"&Hidden Lines Removed");
    AppendMenuW(view, MF_POPUP, (UINT_PTR)display, L"&Display Style");
    AppendMenuW(view, MF_STRING, FW_MENU_PERSPECTIVE, L"P&erspective");
    AppendMenuW(view, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(view, MF_STRING, FW_MENU_PLANES, L"Pla&nes");
    AppendMenuW(view, MF_STRING, FW_MENU_RELATIONS, L"Sketch &Relations");
    AppendMenuW(view, MF_STRING, FW_MENU_DIMENSIONS, L"Sketch Di&mensions");
    AppendMenuW(help, MF_STRING, FW_MENU_ABOUT, L"&About Forge");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)file, L"&File");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)edit, L"&Edit");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)view, L"&View");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)help, L"&Help");
    SetMenu(a->hwnd, bar);
    a->menu = bar;

    ACCEL acc[] = {
        {FVIRTKEY | FCONTROL, 'N', FW_MENU_NEW}, {FVIRTKEY | FCONTROL, 'O', FW_MENU_OPEN}, {FVIRTKEY | FCONTROL, 'S', FW_MENU_SAVE},
        {FVIRTKEY | FCONTROL | FSHIFT, 'S', FW_MENU_SAVE_AS}, {FVIRTKEY | FCONTROL, 'Z', FW_MENU_UNDO}, {FVIRTKEY | FCONTROL, 'Y', FW_MENU_REDO},
        {FVIRTKEY | FCONTROL | FSHIFT, 'Z', FW_MENU_REDO}, {FVIRTKEY | FCONTROL, '1', FW_MENU_FRONT}, {FVIRTKEY | FCONTROL, '2', FW_MENU_BACK},
        {FVIRTKEY | FCONTROL, '3', FW_MENU_LEFT}, {FVIRTKEY | FCONTROL, '4', FW_MENU_RIGHT}, {FVIRTKEY | FCONTROL, '5', FW_MENU_TOP},
        {FVIRTKEY | FCONTROL, '6', FW_MENU_BOTTOM}, {FVIRTKEY | FCONTROL, '7', FW_MENU_ISOMETRIC}, {FVIRTKEY | FCONTROL, '8', FW_MENU_NORMAL_TO},
    };
    a->accel = CreateAcceleratorTableW(acc, (int)(sizeof(acc) / sizeof(acc[0])));
}

static LRESULT CALLBACK mainProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    fw_app *a = appOf(h);
    if (msg == WM_NCCREATE) {
        auto *cs = (CREATESTRUCTW *)lp;
        SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
    }
    if (!a) return DefWindowProcW(h, msg, wp, lp);
    switch (msg) {
    case WM_SIZE:
        layout(a);
        return 0;
    case WM_GETMINMAXINFO: {
        auto *mm = (MINMAXINFO *)lp;
        mm->ptMinTrackSize.x = a->px(1000);
        mm->ptMinTrackSize.y = a->px(640);
        return 0;
    }
    case WM_COMMAND: {
        int id = LOWORD(wp);
        if (id == ID_FILTER && HIWORD(wp) == EN_CHANGE) {
            std::string t = fw_narrow(windowText(a->filter));
            fw_event e = event(FW_EV_FILTER);
            e.text = t.c_str();
            a->emit(e);
            return 0;
        }
        if (id == FW_MENU_EXIT) {
            PostMessageW(h, WM_CLOSE, 0, 0);
            return 0;
        }
        if (id >= FW_MENU_NEW && id <= FW_MENU_ABOUT) a->emit(event(FW_EV_MENU, id));
        return 0;
    }
    case WM_NOTIFY: {
        auto *nm = (NMHDR *)lp;
        if (nm->hwndFrom == a->tab && nm->code == TCN_SELCHANGE) {
            a->emit(event(FW_EV_TAB, (int)SendMessageW(a->tab, TCM_GETCURSEL, 0, 0)));
            return 0;
        }
        if (nm->hwndFrom == a->tree) return treeNotify(a, nm);
        return 0;
    }
    case WM_TIMER:
        a->emit(event(FW_EV_TICK));
        return 0;
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLOREDIT:
        return DefWindowProcW(h, msg, wp, lp);
    case WM_DPICHANGED: {
        a->dpi = HIWORD(wp) / 96.0f;
        RECT *r = (RECT *)lp;
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        buildRibbon(a);
        buildPanel(a);
        return 0;
    }
    case WM_CLOSE:
        a->emit(event(FW_EV_CLOSE));
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        KillTimer(h, 1);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static void registerClass(const wchar_t *name, WNDPROC proc, HBRUSH bg, UINT style = 0) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.style = style;
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = bg;
    wc.lpszClassName = name;
    wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    RegisterClassExW(&wc);
}

static HFONT uiFont(float dpi, int pt, bool bold) {
    NONCLIENTMETRICSW m = {};
    m.cbSize = sizeof(m);
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(m), &m, 0);
    LOGFONTW lf = m.lfMessageFont;
    lf.lfHeight = -(LONG)(pt * dpi * 96 / 72 + 0.5f);
    lf.lfWeight = bold ? FW_SEMIBOLD : FW_NORMAL;
    lstrcpynW(lf.lfFaceName, L"Segoe UI", LF_FACESIZE);
    return CreateFontIndirectW(&lf);
}

extern "C" fw_app *fw_app_create(const char *title, fw_handler handler, void *ctx) {
    enableDpiAwareness();
    enableVisualStyles();
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    auto *a = new fw_app();
    a->handler = handler;
    a->ctx = ctx;
    HDC screen = GetDC(nullptr);
    a->dpi = GetDeviceCaps(screen, LOGPIXELSY) / 96.0f;
    ReleaseDC(nullptr, screen);
    a->font = uiFont(a->dpi, 9, false);
    a->bold = uiFont(a->dpi, 9, true);
    a->smallFont = uiFont(a->dpi, 8, false);
    a->big = uiFont(a->dpi, 11, true);
    a->panelBrush = CreateSolidBrush(kPanel);
    a->messageBrush = CreateSolidBrush(kMessage);
    a->activeBrush = CreateSolidBrush(kAccentSoft);
    a->ribbonBrush = CreateSolidBrush(RGB(0xF2, 0xF2, 0xF4));
    a->fieldBrush = CreateSolidBrush(RGB(0xFF, 0xFF, 0xFF));

    registerClass(kMainClass, mainProc, CreateSolidBrush(kChrome));
    registerClass(kRibbonClass, ribbonProc, nullptr);
    registerClass(kPanelClass, panelProc, nullptr);
    registerClass(kContentClass, contentProc, nullptr);
    registerClass(kViewClass, viewProc, nullptr, CS_DBLCLKS | CS_OWNDC);
    registerClass(kModifyClass, modifyProc, nullptr);

    a->hwnd = CreateWindowExW(0, kMainClass, fw_widen(title).c_str(), WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT, a->px(1440),
                              a->px(900), nullptr, nullptr, GetModuleHandleW(nullptr), a);
    if (!a->hwnd) {
        delete a;
        return nullptr;
    }
    HINSTANCE inst = GetModuleHandleW(nullptr);
    a->tab = CreateWindowExW(0, WC_TABCONTROLW, L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | TCS_FOCUSNEVER, 0, 0, 10, 10, a->hwnd, (HMENU)ID_TAB, inst, nullptr);
    SendMessageW(a->tab, WM_SETFONT, (WPARAM)a->font, TRUE);
    const wchar_t *tabs[] = {L"Features", L"Sketch", L"Evaluate"};
    for (int i = 0; i < 3; ++i) {
        TCITEMW ti = {};
        ti.mask = TCIF_TEXT;
        ti.pszText = (LPWSTR)tabs[i];
        SendMessageW(a->tab, TCM_INSERTITEMW, i, (LPARAM)&ti);
    }
    a->ribbon = CreateWindowExW(0, kRibbonClass, L"", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, 0, 0, 10, 10, a->hwnd, nullptr, inst, nullptr);
    SetWindowLongPtrW(a->ribbon, GWLP_USERDATA, (LONG_PTR)a);
    a->tooltip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, 0, 0, 0, 0, a->hwnd, nullptr, inst, nullptr);
    a->filter = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 0, 0, 10, 10, a->hwnd, (HMENU)ID_FILTER, inst, nullptr);
    SendMessageW(a->filter, WM_SETFONT, (WPARAM)a->font, TRUE);
    SendMessageW(a->filter, EM_SETCUEBANNER, TRUE, (LPARAM)L"Filter features");
    a->tree = CreateWindowExW(0, WC_TREEVIEWW, L"", WS_CHILD | WS_VISIBLE | TVS_HASBUTTONS | TVS_LINESATROOT | TVS_INFOTIP | TVS_FULLROWSELECT | TVS_NOHSCROLL,
                              0, 0, 10, 10, a->hwnd, (HMENU)ID_TREE, inst, nullptr);
    SendMessageW(a->tree, WM_SETFONT, (WPARAM)a->font, TRUE);
    SendMessageW(a->tree, TVM_SETBKCOLOR, 0, (LPARAM)kPanel);
    SendMessageW(a->tree, TVM_SETITEMHEIGHT, a->px(22), 0);
    a->view = CreateWindowExW(0, kViewClass, L"", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, 0, 0, 10, 10, a->hwnd, nullptr, inst, nullptr);
    SetWindowLongPtrW(a->view, GWLP_USERDATA, (LONG_PTR)a);
    a->panel = CreateWindowExW(0, kPanelClass, L"", WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN, 0, 0, 10, 10, a->hwnd, nullptr, inst, nullptr);
    SetWindowLongPtrW(a->panel, GWLP_USERDATA, (LONG_PTR)a);
    a->content = CreateWindowExW(WS_EX_CONTROLPARENT, kContentClass, L"", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, 0, 0, 10, 10, a->panel, nullptr, inst, nullptr);
    SetWindowLongPtrW(a->content, GWLP_USERDATA, (LONG_PTR)a);
    a->status = CreateWindowExW(0, STATUSCLASSNAMEW, L"", WS_CHILD | WS_VISIBLE | SBARS_SIZEGRIP, 0, 0, 0, 0, a->hwnd, (HMENU)ID_STATUS, inst, nullptr);
    SendMessageW(a->status, WM_SETFONT, (WPARAM)a->font, TRUE);

    a->modify = CreateWindowExW(0, kModifyClass, L"", WS_CHILD | WS_CLIPSIBLINGS, 0, 0, a->px(230), a->px(62), a->view, nullptr, inst, nullptr);
    SetWindowLongPtrW(a->modify, GWLP_USERDATA, (LONG_PTR)a);
    a->modifyLabel = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_NOPREFIX, a->px(8), a->px(6), a->px(214), a->px(18), a->modify, nullptr, inst, nullptr);
    SendMessageW(a->modifyLabel, WM_SETFONT, (WPARAM)a->bold, TRUE);
    a->modifyEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, a->px(8), a->px(28), a->px(112), a->px(26), a->modify,
                                    (HMENU)ID_MODIFY_EDIT, inst, nullptr);
    SendMessageW(a->modifyEdit, WM_SETFONT, (WPARAM)a->font, TRUE);
    modifyEditProc = (WNDPROC)SetWindowLongPtrW(a->modifyEdit, GWLP_WNDPROC, (LONG_PTR)modifyFieldProc);
    HWND ok = CreateWindowExW(0, L"BUTTON", L"OK", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, a->px(126), a->px(28), a->px(40), a->px(26), a->modify,
                              (HMENU)ID_MODIFY_OK, inst, nullptr);
    HWND cancel = CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, a->px(170), a->px(28), a->px(52), a->px(26), a->modify,
                                  (HMENU)ID_MODIFY_CANCEL, inst, nullptr);
    SendMessageW(ok, WM_SETFONT, (WPARAM)a->bold, TRUE);
    SendMessageW(cancel, WM_SETFONT, (WPARAM)a->font, TRUE);

    buildMenu(a);
    a->renderer = fw_renderer_create(a->view);
    SetTimer(a->hwnd, 1, 33, nullptr);
    layout(a);
    return a;
}

extern "C" void fw_app_show(fw_app *a) {
    ShowWindow(a->hwnd, SW_SHOWMAXIMIZED);
    UpdateWindow(a->hwnd);
    SetFocus(a->view);
}

extern "C" int fw_app_pump(fw_app *a, int timeout_ms) {
    if (a->quit) return 0;
    MsgWaitForMultipleObjectsEx(0, nullptr, (DWORD)std::max(0, timeout_ms), QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            a->quit = true;
            return 0;
        }
        // While typing in a field, Ctrl+Z / Ctrl+S… belong to the field.
        wchar_t cls[16] = {};
        HWND focus = GetFocus();
        if (focus) GetClassNameW(focus, cls, 16);
        bool typing = lstrcmpiW(cls, L"Edit") == 0;
        if (!typing && a->accel && TranslateAcceleratorW(a->hwnd, a->accel, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return a->quit ? 0 : 1;
}

extern "C" void fw_app_destroy(fw_app *a) {
    if (!a) return;
    if (a->renderer) fw_renderer_destroy(a->renderer);
    if (a->hwnd && IsWindow(a->hwnd)) DestroyWindow(a->hwnd);
    for (HGDIOBJ o : {(HGDIOBJ)a->font, (HGDIOBJ)a->bold, (HGDIOBJ)a->smallFont, (HGDIOBJ)a->big, (HGDIOBJ)a->panelBrush, (HGDIOBJ)a->messageBrush,
                      (HGDIOBJ)a->activeBrush, (HGDIOBJ)a->ribbonBrush, (HGDIOBJ)a->fieldBrush})
        if (o) DeleteObject(o);
    delete a;
}

extern "C" float fw_dpi_scale(fw_app *a) { return a->dpi; }

extern "C" void fw_set_title(fw_app *a, const char *title) { SetWindowTextW(a->hwnd, fw_widen(title).c_str()); }

extern "C" void fw_set_menu_check(fw_app *a, int id, int checked) { CheckMenuItem(a->menu, id, MF_BYCOMMAND | (checked ? MF_CHECKED : MF_UNCHECKED)); }

extern "C" void fw_set_menu_enabled(fw_app *a, int id, int enabled) { EnableMenuItem(a->menu, id, MF_BYCOMMAND | (enabled ? MF_ENABLED : MF_GRAYED)); }

extern "C" void fw_set_status(fw_app *a, const char *left, const char *middle, const char *right) {
    RECT rc;
    GetClientRect(a->hwnd, &rc);
    int parts[3] = {std::max(100, (int)rc.right - a->px(520)), std::max(200, (int)rc.right - a->px(200)), -1};
    SendMessageW(a->status, SB_SETPARTS, 3, (LPARAM)parts);
    SendMessageW(a->status, SB_SETTEXTW, 0, (LPARAM)fw_widen(left).c_str());
    SendMessageW(a->status, SB_SETTEXTW, 1, (LPARAM)fw_widen(middle).c_str());
    SendMessageW(a->status, SB_SETTEXTW, 2, (LPARAM)fw_widen(right).c_str());
}

extern "C" void fw_set_tab(fw_app *a, int index) { SendMessageW(a->tab, TCM_SETCURSEL, index, 0); }

// MARK: ribbon API

extern "C" void fw_ribbon_begin(fw_app *a) {
    a->pendingGroups.clear();
    a->pendingItems.clear();
}

extern "C" void fw_ribbon_group(fw_app *a, const char *title) { a->pendingGroups.push_back(fw_widen(title)); }

extern "C" void fw_ribbon_button(fw_app *a, const char *title, const char *help, int large, int active, int enabled, const char *variants) {
    RibbonItem it;
    it.title = fw_widen(title);
    it.help = fw_widen(help);
    it.large = large != 0;
    it.active = active != 0;
    it.enabled = enabled != 0;
    it.variants = fw_split(variants);
    it.group = std::max(0, (int)a->pendingGroups.size() - 1);
    a->pendingItems.push_back(it);
}

extern "C" void fw_ribbon_end(fw_app *a) {
    bool same = a->pendingGroups == a->groups && a->pendingItems.size() == a->items.size();
    if (same) {
        for (size_t i = 0; i < a->items.size(); ++i) {
            const RibbonItem &n = a->pendingItems[i], &o = a->items[i];
            if (n.title != o.title || n.large != o.large || n.variants != o.variants || n.group != o.group) {
                same = false;
                break;
            }
        }
    }
    if (!same) {
        a->groups = a->pendingGroups;
        a->items = a->pendingItems;
        buildRibbon(a);
        return;
    }
    // Same buttons: update their state only.
    for (size_t i = 0; i < a->items.size(); ++i) {
        a->items[i].active = a->pendingItems[i].active;
        a->items[i].enabled = a->pendingItems[i].enabled;
        HWND b = a->ribbonButtons[i];
        SendMessageW(b, BM_SETCHECK, a->items[i].active ? BST_CHECKED : BST_UNCHECKED, 0);
        EnableWindow(b, a->items[i].enabled);
        if (a->ribbonArrows[i]) EnableWindow(a->ribbonArrows[i], a->items[i].enabled);
    }
}

// MARK: tree API

extern "C" void fw_tree_begin(fw_app *a) { a->pendingNodes.clear(); }

extern "C" void fw_tree_node(fw_app *a, int depth, const char *title, const char *tooltip, int state, int selected, const char *menu) {
    TreeItem n;
    n.depth = depth;
    n.title = fw_widen(title);
    n.tooltip = fw_widen(tooltip);
    n.state = state;
    n.selected = selected != 0;
    n.menu = fw_split(menu);
    a->pendingNodes.push_back(n);
}

extern "C" void fw_tree_end(fw_app *a) {
    if (a->pendingNodes == a->nodes) return;
    bool sameShape = a->pendingNodes.size() == a->nodes.size();
    for (size_t i = 0; sameShape && i < a->nodes.size(); ++i)
        sameShape = a->nodes[i].depth == a->pendingNodes[i].depth && a->nodes[i].title == a->pendingNodes[i].title;
    a->nodes = a->pendingNodes;
    if (!sameShape) {
        buildTree(a);
        return;
    }
    // Same items: update bold state and repaint (colours come from custom draw).
    HTREEITEM stack[64];
    int sp = 0;
    HTREEITEM item = (HTREEITEM)SendMessageW(a->tree, TVM_GETNEXTITEM, TVGN_ROOT, 0);
    while (item) {
        TVITEMW it = {};
        it.mask = TVIF_PARAM;
        it.hItem = item;
        SendMessageW(a->tree, TVM_GETITEMW, 0, (LPARAM)&it);
        size_t i = (size_t)it.lParam;
        if (i < a->nodes.size()) {
            TVITEMW upd = {};
            upd.mask = TVIF_STATE;
            upd.hItem = item;
            upd.stateMask = TVIS_BOLD;
            upd.state = a->nodes[i].selected ? TVIS_BOLD : 0;
            SendMessageW(a->tree, TVM_SETITEMW, 0, (LPARAM)&upd);
        }
        HTREEITEM child = (HTREEITEM)SendMessageW(a->tree, TVM_GETNEXTITEM, TVGN_CHILD, (LPARAM)item);
        HTREEITEM next = (HTREEITEM)SendMessageW(a->tree, TVM_GETNEXTITEM, TVGN_NEXT, (LPARAM)item);
        if (child) {
            if (next && sp < 64) stack[sp++] = next;
            item = child;
        } else if (next) {
            item = next;
        } else {
            item = sp > 0 ? stack[--sp] : nullptr;
        }
    }
    InvalidateRect(a->tree, nullptr, FALSE);
}

// MARK: panel API

static std::wstring pendingTitle, pendingSubtitle, pendingMessage;
static bool pendingOK, pendingCancel;
static std::vector<PanelSection> pendingSections;
static std::vector<PanelControl> pendingControls;

extern "C" void fw_panel_begin(fw_app *a, const char *title, const char *subtitle, const char *message, int has_ok, int has_cancel) {
    (void)a;
    pendingTitle = fw_widen(title);
    pendingSubtitle = fw_widen(subtitle);
    pendingMessage = fw_widen(message);
    pendingOK = has_ok != 0;
    pendingCancel = has_cancel != 0;
    pendingSections.clear();
    pendingControls.clear();
}

static PanelControl &addControl(PanelKind k) {
    if (pendingSections.empty()) pendingSections.push_back(PanelSection{});
    PanelControl c;
    c.kind = k;
    c.section = (int)pendingSections.size() - 1;
    pendingControls.push_back(c);
    return pendingControls.back();
}

extern "C" void fw_panel_section(fw_app *, const char *title, int toggle) {
    PanelSection s;
    s.title = fw_widen(title);
    s.toggle = toggle;
    pendingSections.push_back(s);
}

extern "C" void fw_panel_field(fw_app *, const char *label, const char *unit, const char *value) {
    PanelControl &c = addControl(PK_FIELD);
    c.label = fw_widen(label);
    c.unit = fw_widen(unit);
    c.value = fw_widen(value);
}

extern "C" void fw_panel_check(fw_app *, const char *label, int value) {
    PanelControl &c = addControl(PK_CHECK);
    c.label = fw_widen(label);
    c.on = value != 0;
}

extern "C" void fw_panel_choice(fw_app *, const char *label, const char *options, int selected) {
    PanelControl &c = addControl(PK_CHOICE);
    c.label = fw_widen(label);
    c.options = fw_split(options);
    c.selected = selected;
}

extern "C" void fw_panel_list(fw_app *, const char *items, const char *placeholder, int active) {
    PanelControl &c = addControl(PK_LIST);
    c.items = fw_split(items);
    c.placeholder = fw_widen(placeholder);
    c.active = active != 0;
}

extern "C" void fw_panel_note(fw_app *, const char *text, int warning) {
    PanelControl &c = addControl(PK_NOTE);
    c.label = fw_widen(text);
    c.warning = warning != 0;
}

extern "C" void fw_panel_value(fw_app *, const char *label, const char *value) {
    PanelControl &c = addControl(PK_VALUE);
    c.label = fw_widen(label);
    c.value = fw_widen(value);
}

extern "C" void fw_panel_buttons(fw_app *, const char *titles) {
    PanelControl &c = addControl(PK_BUTTONS);
    c.items = fw_split(titles);
}

extern "C" void fw_panel_rows(fw_app *, const char *texts, const char *details, const char *problems, int deletable) {
    PanelControl &c = addControl(PK_ROWS);
    c.items = fw_split(texts);
    c.details = fw_split(details);
    for (auto &p : fw_split(problems)) c.problems.push_back(p == L"1");
    c.deletable = deletable != 0;
}

extern "C" void fw_panel_end(fw_app *a) {
    a->pTitle = pendingTitle;
    a->pSubtitle = pendingSubtitle;
    a->pMessage = pendingMessage;
    a->pOK = pendingOK;
    a->pCancel = pendingCancel;
    a->sections = pendingSections;
    a->controls = pendingControls;
    a->scroll = 0;
    buildPanel(a);
}

extern "C" void fw_panel_set_text(fw_app *a, int control, const char *value) {
    if (control < 0 || control >= (int)a->controls.size()) return;
    PanelControl &c = a->controls[control];
    c.value = fw_widen(value);
    if (!c.main || GetFocus() == c.main) return;
    if (windowText(c.main) == c.value) return;
    a->building = true;
    SetWindowTextW(c.main, c.value.c_str());
    a->building = false;
}

extern "C" void fw_panel_set_check(fw_app *a, int control, int value) {
    if (control < 0 || control >= (int)a->controls.size() || !a->controls[control].main) return;
    a->controls[control].on = value != 0;
    SendMessageW(a->controls[control].main, BM_SETCHECK, value ? BST_CHECKED : BST_UNCHECKED, 0);
}

extern "C" void fw_panel_set_choice(fw_app *a, int control, int index) {
    if (control < 0 || control >= (int)a->controls.size() || !a->controls[control].main) return;
    a->controls[control].selected = index;
    a->building = true;
    SendMessageW(a->controls[control].main, CB_SETCURSEL, index, 0);
    a->building = false;
}

// MARK: Modify box

extern "C" void fw_edit_show(fw_app *a, int x, int y, const char *label, const char *value) {
    RECT rc;
    GetClientRect(a->view, &rc);
    int w = a->px(230), h = a->px(62);
    x = std::max(4, std::min(x + a->px(12), (int)rc.right - w - 4));
    y = std::max(4, std::min(y + a->px(12), (int)rc.bottom - h - 4));
    SetWindowTextW(a->modifyLabel, fw_widen(label).c_str());
    bool wasVisible = IsWindowVisible(a->modify) != 0;
    std::wstring v = fw_widen(value);
    if (!wasVisible || windowText(a->modifyEdit) != v) SetWindowTextW(a->modifyEdit, v.c_str());
    SetWindowPos(a->modify, HWND_TOP, x, y, w, h, SWP_SHOWWINDOW);
    if (!wasVisible) {
        SetFocus(a->modifyEdit);
        SendMessageW(a->modifyEdit, EM_SETSEL, 0, -1);
    }
}

extern "C" void fw_edit_hide(fw_app *a) {
    if (!IsWindowVisible(a->modify)) return;
    ShowWindow(a->modify, SW_HIDE);
    SetFocus(a->view);
}

// MARK: dialogs

extern "C" int fw_confirm(fw_app *a, const char *title, const char *message, const char *yes, const char *no) {
    std::wstring t = fw_widen(title), m = fw_widen(message), y = fw_widen(yes), n = fw_widen(no);
    if (taskDialogIndirect) {
        TASKDIALOG_BUTTON buttons[2] = {{IDYES, y.c_str()}, {IDNO, n.c_str()}};
        TASKDIALOGCONFIG c = {};
        c.cbSize = sizeof(c);
        c.hwndParent = a->hwnd;
        c.pszWindowTitle = L"Forge";
        c.pszMainInstruction = t.c_str();
        c.pszContent = m.c_str();
        c.cButtons = 2;
        c.pButtons = buttons;
        c.nDefaultButton = IDNO;
        int pressed = 0;
        if (SUCCEEDED(taskDialogIndirect(&c, &pressed, nullptr, nullptr))) return pressed == IDYES;
    }
    return MessageBoxW(a->hwnd, (t + L"\n\n" + m).c_str(), L"Forge", MB_YESNO | MB_ICONQUESTION) == IDYES;
}

static char *dup(const std::wstring &w) {
    std::string s = fw_narrow(w);
    char *out = (char *)malloc(s.size() + 1);
    memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

extern "C" char *fw_save_dialog(fw_app *a, const char *suggested_name) {
    wchar_t file[MAX_PATH] = {};
    lstrcpynW(file, fw_widen(suggested_name).c_str(), MAX_PATH);
    OPENFILENAMEW ofn = {};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = a->hwnd;
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrFilter = L"All files\0*.*\0";
    ofn.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetSaveFileNameW(&ofn)) return nullptr;
    return dup(file);
}

extern "C" char *fw_open_dialog(fw_app *a) {
    // A .forgepart document is a folder: pick folders.
    IFileOpenDialog *dlg = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)))) return nullptr;
    DWORD opts = 0;
    dlg->GetOptions(&opts);
    dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    dlg->SetTitle(L"Open a Forge part (.forgepart)");
    char *out = nullptr;
    if (SUCCEEDED(dlg->Show(a->hwnd))) {
        IShellItem *item = nullptr;
        if (SUCCEEDED(dlg->GetResult(&item))) {
            PWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
                out = dup(path);
                CoTaskMemFree(path);
            }
            item->Release();
        }
    }
    dlg->Release();
    return out;
}

extern "C" void fw_message(fw_app *a, const char *title, const char *message, int error) {
    MessageBoxW(a->hwnd, fw_widen(message).c_str(), fw_widen(title).c_str(), MB_OK | (error ? MB_ICONERROR : MB_ICONINFORMATION));
}

extern "C" void fw_free(void *p) { free(p); }

extern "C" uint8_t *fw_capture(fw_app *a, int *width, int *height) {
    RECT rc;
    GetClientRect(a->hwnd, &rc);
    int w = rc.right, h = rc.bottom;
    if (w <= 0 || h <= 0) return nullptr;
    HDC screen = GetDC(a->hwnd);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;  // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HBITMAP bmp = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    uint8_t *out = nullptr;
    if (bmp && bits) {
        HGDIOBJ old = SelectObject(mem, bmp);
        // PW_CLIENTONLY | PW_RENDERFULLCONTENT: includes the Direct3D content.
        if (!PrintWindow(a->hwnd, mem, 0x1 | 0x2)) BitBlt(mem, 0, 0, w, h, screen, 0, 0, SRCCOPY);
        GdiFlush();
        out = (uint8_t *)malloc((size_t)w * h * 4);
        const uint8_t *src = (const uint8_t *)bits;
        for (int i = 0; i < w * h; ++i) {
            out[4 * i] = src[4 * i + 2];
            out[4 * i + 1] = src[4 * i + 1];
            out[4 * i + 2] = src[4 * i];
            out[4 * i + 3] = 255;
        }
        SelectObject(mem, old);
    }
    if (bmp) DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(a->hwnd, screen);
    if (out) {
        *width = w;
        *height = h;
    }
    return out;
}

extern "C" void fw_app_quit(fw_app *a) { PostMessageW(a->hwnd, WM_CLOSE, 0, 0); }

extern "C" void fw_view_invalidate(fw_app *a) { InvalidateRect(a->view, nullptr, FALSE); }

extern "C" void fw_view_size(fw_app *a, int *width, int *height) {
    RECT rc;
    GetClientRect(a->view, &rc);
    if (width) *width = rc.right;
    if (height) *height = rc.bottom;
}

extern "C" void fw_view_focus(fw_app *a) { SetFocus(a->view); }
