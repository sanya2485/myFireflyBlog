---
title: "Coze 聊天窗 z-index 与 Swup 切页适配修复"
published: 2026-08-06
description: "Coze 聊天窗接入 Swup SPA 切页遇到的三个坑：z-index 层级被遮挡、切页后悬浮球消失、SDK 注入样式被 SwupHeadPlugin 清空"
tags: [Coze, Swup, Astro, 前端, 聊天窗]
category: 技术实践
draft: false
---

博客的 Coze AI 助手聊天窗接入 Swup 做 SPA 切页后，陆续踩了三个相互独立的坑：聊天窗被浮动控件遮挡、切页后悬浮球图标永久消失、聊天窗"打不开"其实是 SDK 注入的样式被切页清掉了。这篇文章记录这三个问题的根因和修法。

## z-index 层级

聊天窗默认 `ui.base.zIndex` 是 1000，和博客的浮动控件（FloatingControls 1000 / FloatingTOC 999/1001）同级，会被遮住。把它提到 **1020**：

- 聊天窗：`ui.base.zIndex = 1020`
- 悬浮球：1010
- toast：9999

之后如果再被遮挡，按这张层级表往上调即可。

## Swup 切页重置（修复悬浮球图标消失）

**根因**：悬浮球和 SDK 容器在 `#swup-container` 之外，跨页存活；聊天窗开着时切页，`coze-chat-open` class 残留 → 悬浮球永久消失。

**修法**：注册 `content:replace` 回调，切页时收起聊天窗：

```js
window.swup.hooks.on("content:replace", () => {
  document.body.classList.remove("coze-chat-open");
  cozeClient.hideChatBot();
});
```

注册时做兜底判断：`if (window.swup && window.swup.hooks)` 已就绪直接用，否则监听 `swup:enable` 事件（布局层 dispatch）。

## SwupScriptsPlugin 重跑脚本坑

SwupScriptsPlugin 默认 scope 是整个 document，每次 `content:replace`（**含首次加载**）会重跑所有没带 `data-swup-ignore-script` 的 `<script>`。对 CozeChat 的破坏链：

1. 重跑 → 新 IIFE 里 `cozeClient` 归零
2. `bindCozeWidget` 把悬浮球重绑到空客户端
3. 重跑时 `readyState` 已是 complete，走 `requestIdleCallback(initCozeChat, 500)` 分支
4. 第二参传数字抛 `TypeError`（`Argument 2 can't be converted to a dictionary`）
5. `initCozeChat` 永不执行 → 点悬浮球只弹 toast，聊天窗永远打不开

**修复**：

- 内联脚本加 `data-swup-ignore-script`，让浮窗独立于页面只初始化一次
- `requestIdleCallback` 第二参从数字改成 `{ timeout: 500 }`

**通用教训**：任何 `is:inline` 内联脚本如果声明了跨页状态（IIFE 内的 `var`），都必须加 `data-swup-ignore-script` 防止 Swup 重跑，否则状态会被第二次执行清零。

## SwupHeadPlugin 清 `<style>` 坑

Coze SDK 初始化时会往 `<head>` 动态注入约 230 个 `<style>`（聊天窗 `position:fixed`、`.coz-layout` 布局、`.light-theme` 主题变量、哈希类名组件样式）。之前为了做切页动画启用了 SwupHeadPlugin（`updateHead: true`），它每次切页用新页面 head 替换当前 head → SDK 注入的运行时样式全被删（实测 headStyleCount 237→5）→ 聊天窗失去 `position:fixed`、退化成 `static` 跑到左上角。表现就是"切页后打不开"，其实 `cozeClient` 活着、`showChatBot()` 也执行了，只是样式没了。

**修法**：`updateHead` 从 `true` 改成：

```js
updateHead: { persistTags: "style" }
```

这是 SwupHeadPlugin 官方选项，让所有内联 `<style>` 跨页存活。博客自身页面特异样式都是 scoped（`data-astro-cid-*` / `svelte-*`），保留无副作用。

**补充认知**：SDK 注入的样式里只有 129 个含 "coze"、其中 18 个不含 "coze-chat-sdk" 标记（面板定位是哈希类名规则）→ **按内容字符串匹配不可靠**，别用 `textContent.includes` 当 persistTags 判断条件。`persistTags` 支持 boolean / CSS 选择器字符串 / 函数三种形式，能用字符串选择器就别用函数。

## 实现位置

- `src/components/widget/CozeChat.astro`：`resetCozeOnNavigate()`（切页收起聊天窗）+ `ui.base.zIndex: 1020`
- `astro.config.mjs`：`updateHead: { persistTags: "style" }`

这两个坑（脚本重跑 / head 样式被清）是两条独立破坏路径，之前只修了脚本重跑，没挡住样式被清——排查"切页后组件失灵"类问题时，建议先从这两个维度各自验证一遍。

关联阅读：[Coze 浮窗 UI 定制实战：从 SDK 配置到自建悬浮球](/posts/coze-widget-ui-customization/)
