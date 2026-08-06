---
title: "Coze 浮窗 UI 定制实战：从 SDK 配置到自建悬浮球"
published: 2026-08-06
description: "Coze Web SDK 1.2.0-beta.19 浮窗 UI 定制要点（语言、标题、footer、悬浮球、z-index），以及 CozeChat.astro 自建悬浮球与问候气泡的完整改造实录"
tags: [Coze, WebChatClient, 前端, UI, 悬浮球]
category: 技术实践
draft: false
---

博客的 Coze AI 助手用自建悬浮球 + 问候气泡替换了 SDK 默认的入口，全程逆向 Web SDK 1.2.0-beta.19（cn build）确认配置项行为。这篇文章整理 SDK 浮窗 UI 定制要点和改造中踩的坑。

## SDK 浮窗 UI 定制要点（逆向确认）

- **英文 UI 根源**：`ui.base.lang` 默认 `"en"`，不设置就是英文界面，设 `"zh-CN"` 全转中文。
- **header 标题**：默认硬编码 `"Coze Bot"`，用 `ui.header.title` 覆盖。
- **footer 链接**：默认「由 扣子 提供支持，AI生成仅供参考」，「扣子」是链接，用 `ui.footer.isShow=false` 或 `ui.footer.expressionText` 控制。
- **悬浮球 asstBtn**：只有 `{ isNeed }` 一个配置项，图标走 `ui.base.icon`，class 是 hash 过的 CSS module → **靠 CSS 覆写样式不可靠，要自定义样式就 `isNeed:false` + 自建**。
- **编程控制**：client 暴露 `showChatBot()` / `hideChatBot()`；生命周期回调 `ui.chatBot.onShow/onHide/onBeforeShow/onBeforeHide`。
- **`ui.chatBot.el`**：可把聊天窗 portal 到自定义容器；顶层 `el` 会把整个 app（球+窗）放进容器。
- **`ui.base.zIndex`** 默认 1000，聊天窗与悬浮球共用 → 和博客浮动控件同级，需要提层（相关方案见 [Coze 聊天窗 z-index 与 Swup 切页适配修复](/posts/coze-chat-theme-zindex/)）。

## 自建悬浮球与问候气泡

### 悬浮球

自建悬浮球 `#coze-ball` 固定在右下角 56px，静止时 `translateY(28px)` 半隐藏（下半截压出视口），hover 弹出 `translateY(-16px)` 带回弹（`cubic-bezier(0.34,1.56,0.64,1)`）。

**hover 抖动坑（已修）**：hover 判定绝不能绑在会移动的元素上。原来 `.coze-ball:hover` 触发 `transform`，动画途中球带着判定框上移，鼠标位置不变就脱离 `:hover` → 弹出/缩回循环抖动。

**修法**：加一个不移动的 `.coze-hitbox`（56×40，锚定右下角，`pointer-events:auto`），hover 用 `.coze-hitbox:hover .coze-ball`，球在框内纯视觉位移；点击也绑 hitbox（球是其子元素会冒泡）。移动端 hitbox 48×32。

### 问候气泡

问候气泡 `#coze-bubble` 文案「hi~请问有什么问题吗？」，每次打开都弹；× 仅本次关闭 / 3s 自动关；气泡内「不再显示」按钮写 `coze_greeting_off` 永久停用（此前是 `coze_greeting_seen`"仅首次"语义，已改）。

**坑**：`clearCozeSessionCache()` 会清掉所有 `coze_`/`COZE_` 前缀的 key（只留 `coze_visitor_id`）。新加的持久化标记必须进白名单，否则每次刷新被清。

## 问候气泡最终样式（模板 09）

- 定位在悬浮球**左上方**：桌面 `right:32px; bottom:84px`，移动端 `right:24px; bottom:40px`；尾巴 `right:20px; bottom:-8px`（14px 方块 45°）指向球（移动端 `right:14px`）。
- **样式**：圆体字（`"MiSans","HarmonyOS Sans SC","PingFang SC","Microsoft YaHei"`）+ 20px 大圆角。**颜色跟随主题色相**（改 `--hue` 会同步变）：用 `color-mix(in oklab, var(--primary) 10%, var(--card-bg))` 调淡主题色底、`primary 30% + --line-divider` 描边、`primary 16% transparent` 阴影；文字亮色 `--deep-text`、暗色 `html.dark` 覆盖为 `--btn-content`。不支持 `color-mix` 时降级 `--btn-regular-bg`/`--line-divider`。
- **坍缩 bug（重要）**：容器 `.coze-widget` 是 `width:0`，气泡仅设 `right` 无显式宽度 → 绝对定位子元素走 shrink-to-fit，可用宽度为 0 → 坍缩成约 58px 窄条（"字体难看"的根因）。**修法**：气泡加 `width:max-content; max-width:230px`（显式非 auto 宽度避开 shrink-to-fit 分支）。移动端 `max-width:190px`。
- **气泡显示期间球要弹出**：`.coze-widget.coze-has-bubble .coze-ball { transform: translateY(-16px) }`（否则球保持 28px 半隐，气泡尾巴会悬空 56px）。

## 如何应用

改 Coze 浮窗样式/行为时：先查上面的 SDK 配置表，别去覆写 SDK 的 hash class；需要自定义交互就 `asstBtn.isNeed:false` 自建，再调 `showChatBot()`。聊天窗被遮挡或切页失灵的问题，看 [Coze 聊天窗 z-index 与 Swup 切页适配修复](/posts/coze-chat-theme-zindex/)。
