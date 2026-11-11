# Whole Word uses ICU word segmentation at edges that touch unspaced scripts

**Decision.** `TextSearchWordBoundary` keeps its scalar rule (Unicode letters, numbers and
`_` are word characters; an edge holds when the character outside the match is not one).
Where the rule would reject an edge and the character on either side of it is Han, kana,
Thai, Lao, Khmer or Myanmar, the edge is decided by ICU word segmentation instead:
`CFStringTokenizer` with `kCFStringTokenizerUnitWordBoundary` and the root locale. After a
rejected candidate the scanner also restarts at such positions instead of skipping the
rest of the run. This applies to editor Find, Replace and workspace search, which share
`TextSearchEngine`.

**Why.** Every Han ideograph and kana is a letter, so inside running text no position was
a word edge and Whole Word found nothing: 中文 in 我喜歡中文。 and Swift in 使用Swift開發
both returned 0 matches. Segmentation finds both (我|喜歡|中文, 使用|Swift|開發) and still
rejects part of a word (喜 inside 喜歡). The root locale makes results independent of the
user's language settings; the `ja` and `zh-Hans` locales segmented Traditional Chinese
text worse in a probe (撰寫部落格 became 撰|寫|部落|格).

Segmentation reads one window at a time: 128 UTF-16 units before the queried edge and 1,024
after it, trusting only boundaries at least 64 units inside the window or at a document
end. Candidates are examined in increasing order, so a scan tokenizes about 1.2 times the
text even for one unbroken run of Han text (`testUnbrokenHanRunTokenizesLinearly`: 100,000
rejected candidates over 500,000 units). A search that never meets these scripts creates
no tokenizer.

**Alternatives considered.**

- Segment every edge (full UAX #29). Rejected: it changes Latin results the existing tests
  pin, such as `item½` and `don't` (UAX #29 keeps `don't` and `e.g` as one word).
- Treat unspaced-script characters as never joining their neighbours. Simpler and
  dictionary-free, but Whole Word would then degrade to substring search for a Chinese
  query (喜 would match inside 喜歡).
- `enumerateSubstrings(options: .byWords)`. Same segmentation, but it skips separators and
  has no window control.

Hangul keeps the scalar rule: Korean separates words with spaces, and UAX #29 also treats
Hangul syllables as letters. `testWholeWordTreatsLettersNumbersAndUnderscoreAsWordCharacters`
now pins that with 한국어 instead of 文字学, which the dictionary splits as 文字|学.
