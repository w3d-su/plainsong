# Lane 04 device acceptance

These boxes are open. Simulator tests do not check them. Lane 01 has not accepted M0.

Record the device model, OS, app build, source SHA, and fixture hashes before any box can be checked.

- [ ] Traditional Chinese Zhuyin: composition, candidate confirmation, caret, and native Undo/Redo on the hardware and software keyboards.
- [ ] Traditional Chinese Pinyin: the same sequence.
- [ ] Switch away and back, and background the app, while a candidate is marked. The mark is not committed or cleared by the editor, and a late highlight does not land inside it.
- [ ] Undo after confirming a candidate restores the pre-candidate source in one step. Redo restores it.
- [ ] A format or image command during an open candidate does nothing to the source and does not close the candidate.
- [ ] Hide the editor for preview, then show it. Selection, undo stack, and an open candidate are still there.
- [ ] 100 KB and 1 MB fixtures: keystroke p95 under 16 ms, visible highlight under 50 ms, measured on device. The simulator scan in the lane 04 receipt is not this measurement.

Owner steps: install a build that contains this lane's `IOSSourceEditorController`, open a Markdown file, and run the list above. Leave the boxes unchecked in git until that record exists.
