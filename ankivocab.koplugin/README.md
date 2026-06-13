# Anki 单词卡片（Anki vocabulary cards）

把 KOReader 内置的「单词本（Vocabulary builder）」复习体验改造成 **Anki 式的间隔重复 + 翻卡** 模式：正面看单词和它出现时的**上下文句子**，翻面看**中文释义**（自动查本机词典），再用「重来 / 困难 / 良好 / 简单」给自己打分，安排下次复习时间。

## 功能

- **Anki 式翻卡**：
  - 正面：单词（大字）、来源书名、以及收集这个词时的上下文句子（目标词用 `【】` 标出）。
  - 点击卡片任意处（或点「显示答案」）翻面。
  - 翻面后追加显示**中文释义**：第一次翻面时用本机安装的词典（sdcv/StarDict）自动查询，并缓存到数据库，之后秒开。
- **间隔重复评分**：四个按钮「重来 / 困难 / 良好 / 简单」，每个按钮上直接显示下次复习间隔（如「良好 1天」「简单 4天」），采用类 Anki 的 SM-2 算法（ease 因子、毕业间隔、遗忘重学）。
- **单词来源**：自动从内置单词本的数据库 `vocabulary_builder.sqlite3` 导入（含上下文、书名）。你照常在阅读时查词并「加入单词本」即可，新词会在每次打开本插件 / 开始复习时自动同步进来；重复导入不会覆盖已有卡片的复习进度。
- **菜单**（文件管理器和阅读器的「更多工具」里都有「Anki 单词卡片」）：
  - 开始复习（显示当前到期卡片数）
  - 从单词本导入新单词
  - 统计（总卡片 / 到期 / 未学过）

## 安装（Kindle）

1. 把 `ankivocab.koplugin` 整个文件夹复制到 Kindle 的 `koreader/plugins/` 目录
   （USB 连电脑后通常是 `/mnt/us/koreader/plugins/ankivocab.koplugin/`）。
2. 重启 KOReader。
3. 在主菜单「更多工具 → Anki 单词卡片」里开始复习。其他设备（Kobo、Android 等）复制到对应的 `koreader/plugins/` 即可。

## 说明

- **中文释义依赖本机词典**：需要装一部英汉（或其他语言→中文）StarDict 词典，KOReader 才能查到中文。没有装词典时卡片会显示「（未找到释义）」，其余功能照常。词典安装方法见 KOReader Wiki 的 “Dictionary support”。
- 复习进度存在独立数据库 `settings/anki_vocab.sqlite3`，与内置单词本互不干扰（不会改动内置单词本的数据）。
- 间隔算法参数（毕业间隔、ease 调整等）集中在 `db.lua` 顶部，可自行调整。

---

An Anki-style spaced-repetition review mode for KOReader's vocabulary. Front of each flashcard shows the word and the sentence context it was collected in; tap to flip and reveal the Chinese meaning (looked up once via the installed StarDict dictionaries and cached). Rate recall with 重来/困难/良好/简单 (Again/Hard/Good/Easy), scheduled with an SM-2-like algorithm. Words are imported non-destructively from the built-in Vocabulary builder's database. Install by copying `ankivocab.koplugin` into `koreader/plugins/` and restarting KOReader; find it under "More tools → Anki 单词卡片".
