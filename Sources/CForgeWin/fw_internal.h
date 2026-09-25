// Internal state of the Windows shell (see include/CForgeWin.h).

#pragma once

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <string>
#include <vector>

#include "CForgeWin.h"

struct fw_renderer;

std::wstring fw_widen(const char *s);
std::string fw_narrow(const std::wstring &s);
std::vector<std::wstring> fw_split(const char *s);

struct RibbonItem {
    std::wstring title, help;
    bool large = true, active = false, enabled = true;
    std::vector<std::wstring> variants;
    int group = 0;
};

struct TreeItem {
    int depth = 0;
    std::wstring title, tooltip;
    int state = FW_NODE_NORMAL;
    bool selected = false;
    std::vector<std::wstring> menu;
    bool operator==(const TreeItem &o) const {
        return depth == o.depth && title == o.title && tooltip == o.tooltip && state == o.state && selected == o.selected && menu == o.menu;
    }
};

enum PanelKind { PK_FIELD, PK_CHECK, PK_CHOICE, PK_LIST, PK_NOTE, PK_VALUE, PK_BUTTONS, PK_ROWS };

struct PanelControl {
    PanelKind kind = PK_NOTE;
    int section = -1;
    std::wstring label, unit, value, placeholder;
    bool on = false, active = false, warning = false, deletable = false;
    int selected = -1;
    std::vector<std::wstring> options, items, details;
    std::vector<bool> problems;
    // Native controls: `main` receives the value; `extra` are labels and sub-buttons.
    HWND main = nullptr;
    std::vector<HWND> extra;
};

struct PanelSection {
    std::wstring title;
    int toggle = -1;
    HWND hwnd = nullptr;
};

struct fw_app {
    HWND hwnd = nullptr, tab = nullptr, ribbon = nullptr, filter = nullptr, tree = nullptr, panel = nullptr, content = nullptr;
    HWND view = nullptr, status = nullptr, tooltip = nullptr;
    HWND modify = nullptr, modifyLabel = nullptr, modifyEdit = nullptr;
    HMENU menu = nullptr;
    HACCEL accel = nullptr;
    fw_handler handler = nullptr;
    void *ctx = nullptr;
    HFONT font = nullptr, bold = nullptr, small = nullptr, big = nullptr;
    HBRUSH panelBrush = nullptr, messageBrush = nullptr, activeBrush = nullptr, ribbonBrush = nullptr, fieldBrush = nullptr;
    float dpi = 1;
    bool quit = false;
    bool building = false;  // suppress change notifications while controls are created or set

    // Ribbon
    std::vector<std::wstring> groups, pendingGroups;
    std::vector<RibbonItem> items, pendingItems;
    std::vector<HWND> ribbonButtons, ribbonArrows;
    std::vector<RECT> groupRects;

    // Tree
    std::vector<TreeItem> nodes, pendingNodes;

    // PropertyManager
    std::wstring pTitle, pSubtitle, pMessage;
    bool pOK = false, pCancel = false;
    std::vector<PanelSection> sections;
    std::vector<PanelControl> controls;
    std::vector<HWND> panelChrome;  // header, message, OK / Cancel
    HWND messageHwnd = nullptr;
    int scroll = 0, contentHeight = 0;

    fw_renderer *renderer = nullptr;

    void emit(fw_event e) {
        if (handler) handler(ctx, &e);
    }
    int px(float dip) const { return (int)(dip * dpi + 0.5f); }
};

// Renderer (render.cpp)
fw_renderer *fw_renderer_create(HWND view);
void fw_renderer_destroy(fw_renderer *);
void fw_renderer_resize(fw_renderer *, int width, int height);
