# Stick a book on top（置顶书籍）

一个 KOReader 插件（适用于 Kindle 及其他所有 KOReader 设备）：在文件浏览器里**长按**书籍或文件夹，即可把它**置顶**到当前文件夹列表的最前面。

## 功能

- 长按书籍，弹出的选项卡里会出现「📌 置顶书籍」按钮；再次长按已置顶的书则显示「📌 取消置顶（当前第 N 本）」。
- 最多可置顶 **4 本书**。已有置顶时，选项卡会列出「置顶到第一本」「置顶到第二本」……可以指定插入位置，也可以用同样的按钮调整已置顶书籍的顺序。
- 文件夹同样支持置顶，最多 **2 个**，按钮为「置顶到第一个」「置顶到第二个」。
- 达到上限后会显示「置顶已满」提示，需先取消一个再置顶新的。
- 置顶的条目排在所在文件夹列表的最顶端（`../` 之下）：先置顶文件夹、后置顶书籍，再排主页快捷方式，各自按置顶顺序排列。
- **主页快捷方式**：当置顶的书不在主页（HOME 文件夹）里时，会在主页顶部自动生成一个**快捷方式**。快捷方式跟书本身一样（同样的封面、名字、阅读状态），点击直接打开真实文件；原文件位置不变，且仍然在它自己的文件夹里保持置顶。已经在主页里的书不会重复生成快捷方式。
- 标记区分：
  - 在 CoverBrowser 的**封面网格 / 封面列表**视图中：置顶条目封面**左上角**是图钉角标；主页快捷方式封面**右上角**是一个"外链/打开"角标（均为黑色图标 + 白色描边，深色封面上也清晰可见）。
  - 在经典文件名视图中：置顶条目名字前是图钉字形，快捷方式名字前是外链字形。
- 置顶状态保存在 `settings/stick_a_book_on_top.lua`，重启后保留；被删除或移动的条目会自动从置顶中清除（对应的主页快捷方式也随之消失）。

## 安装（Kindle）

1. 把 `stickabookontop.koplugin` 整个文件夹复制到 Kindle 的 `koreader/plugins/` 目录下
   （USB 连接电脑后通常是 `koreader/plugins/stickabookontop.koplugin/`，设备上路径为 `/mnt/us/koreader/plugins/`）。
2. 重启 KOReader。
3. 在文件浏览器里长按任意书籍或文件夹即可看到置顶按钮。

其他设备（Kobo、PocketBook、Android 等）同理，复制到对应的 `koreader/plugins/` 目录即可。

## 说明

- 需要较新版本的 KOReader（带有 `FileManager.addFileDialogButtons` 接口，2024 年中以后的版本均可）。旧版本上插件不会崩溃，但长按选项卡中不会出现置顶按钮。
- 置顶只影响文件浏览器的排序显示，不会改动磁盘上的任何文件。

---

A KOReader plugin that lets you pin books (up to 4) and folders (up to 2) to the top of the file browser. Long-press an entry to pin it to a chosen position ("pin as 1st", "pin as 2nd", …), move it, or unpin it. Pinned entries are sorted to the top of their folder listing and marked with a pushpin badge at the top-left corner of their cover (CoverBrowser mosaic/list modes) or a pushpin glyph before the file name (classic mode). Any pinned book that lives outside the HOME folder also gets a shortcut at the top of the HOME folder: it shows the real cover/name, opens the real file, and is marked with an "open-in-new" badge at its top-right corner; the real file stays put and stays pinned. Install by copying `stickabookontop.koplugin` into `koreader/plugins/` and restarting KOReader.
