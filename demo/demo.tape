Output demo.gif

Require tmux
Require nvim
Require pi

Set Shell "bash"
Set FontSize 14
Set Width 1036
Set Height 600
Set WindowBar Colorful
Set Padding 0
Set Theme "Rose Pine"
Set TypingSpeed 50ms
Set Framerate 24
Set PlaybackSpeed 1

# ─────────────────────────────────────────────────────────────
# Start tmux with neovim (top) and pi (bottom)
# ─────────────────────────────────────────────────────────────

Hide

Set TypingSpeed 1ms
Type "tmux new-session -d -s demo -x 200 -y 50 'nvim index.ts' && tmux split-window -h -p 40 -t demo 'pi' && tmux select-pane -t demo:.0 && tmux attach -t demo"
Enter
Set TypingSpeed 50ms
Sleep 3s

Show

# ─────────────────────────────────────────────────────────────
# 1. Ask what the file does (send full buffer)
# ─────────────────────────────────────────────────────────────

Sleep 1s
Type ",p"
Sleep 400ms
Tab
Sleep 400ms
Type "What does this file do in one sentence?"
Sleep 400ms
Enter

Sleep 200ms

# ─────────────────────────────────────────────────────────────
# 1b. Switch to pi pane and ask for the repo link
# ─────────────────────────────────────────────────────────────

# tmux prefix (Ctrl-B) then down arrow to switch to pi pane
Ctrl+B
Sleep 200ms
Right
Sleep 1s

Type "Give me a link to this repo"
Enter

Sleep 2s

# Switch back to nvim pane
Ctrl+B
Sleep 200ms
Left
Sleep 500ms

# ─────────────────────────────────────────────────────────────
# 2. Go to line 81, select it, ask to remove the ! assertion
# ─────────────────────────────────────────────────────────────

Type "79G"
Sleep 400ms
Type "V"
Type "5j"
Sleep 900ms

Type ",p"
Sleep 400ms
Type "Add a type guard so the ! assertion isn't needed"
Sleep 200ms
Enter

Sleep 6s

# ─────────────────────────────────────────────────────────────
# 3. Go to top, ask to add a shebang (no buffer)
# ─────────────────────────────────────────────────────────────

Escape
Sleep 200ms
Type "gg"
Sleep 400ms

Type ",p"
Sleep 400ms
Type "Add a shebang to the top of this file"
Sleep 400ms
Enter

Sleep 5s

# ─────────────────────────────────────────────────────────────
# Teardown: exit pi and neovim, end tmux session, restore files
# ─────────────────────────────────────────────────────────────

Hide

Set TypingSpeed 1ms
# Exit neovim
Type ":qa!"
Enter
Sleep 500ms

# Exit pi
Type "exit"
Enter
Sleep 500ms

# Kill tmux session
Type "tmux kill-server"
Enter
Sleep 500ms

# Restore file
Type "git restore index.ts"
Enter

Show
