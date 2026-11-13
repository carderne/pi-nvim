" Minimal init for the headless test suite: no user configuration, just the
" plugin under test on the runtimepath.
set nocompatible
let s:plugin_root = expand('<sfile>:p:h:h')

" A wrapper around `nvim` (nix, asdf, …) may paste its own runtimepath and
" packpath ahead of ours, which would load a user config's `plugin/` scripts and
" a packaged copy of this plugin on top of the one under test. Pin both to the
" plugin and $VIMRUNTIME so a run only ever sees this checkout.
execute 'set runtimepath=' . fnameescape(s:plugin_root) . ',' . fnameescape($VIMRUNTIME)
execute 'set packpath=' . fnameescape($VIMRUNTIME)

" run.sh exports an isolated socket directory; make sure nothing falls back to
" the real /tmp/pi-nvim-sockets if it ever stops doing so.
if empty($PI_NVIM_SOCKETS_DIR)
  echoerr 'PI_NVIM_SOCKETS_DIR must be set by test/run.sh'
endif

set noswapfile
set shortmess+=c
