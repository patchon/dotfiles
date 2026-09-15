" Enable syntax highlighting,
syntax on

" Enable file type plug,
filetype plugin on
filetype indent on

" Fast saving,
map qq :w!<cr>

" Toggle spell checking,
map ää :setlocal spell!<cr>

" Never do sudo vim again,
cmap w!! w !sudo tee %

" Everything vim writes for itself lives under ~/.cache/vim: backups, swap
" and undo files in one directory each, so that only backups are ever
" purged, plus netrw's directory history and the viminfo file. The
" trailing // makes vim encode the full path into the file name, so
" same-named files in different directories do not collide.
let s:cache_dir = $HOME . '/.cache/vim'
for s:sub in ['backup', 'swap', 'undo']
  call mkdir(s:cache_dir . '/' . s:sub, 'p', 0700)
endfor
set backup
set writebackup
set backupdir=~/.cache/vim/backup//
set directory=~/.cache/vim/swap//
set undodir=~/.cache/vim/undo//
set undofile
set viminfofile=~/.cache/vim/viminfo
let g:netrw_home = s:cache_dir

" Keep every version: the backup extension carries the time of the save.
au BufWritePre * let &backupext = '@' . strftime('%F.%H.%M')

" Purge backups older than 30 days at startup.
for s:file in glob(s:cache_dir . '/backup/*', 1, 1)
  if getftime(s:file) < localtime() - 30 * 86400
    call delete(s:file)
  endif
endfor

" Set some reasonable defaults
set autoindent            " Simple indent
set cmdheight=2           " Height of the command bar
set cursorline            " highlight current line
set encoding=utf-8        " Show files in utf8
set expandtab             " Inserts <softtabstop-nr-of-spaces> instead of tabs
set fileencodings=utf-8   " Save files in utf8
set hlsearch              " Highlight search results
set ic                    " Ignore case while searching
set incsearch             " Search while typing
set laststatus=2          " Always show the status line
set lazyredraw            " Don't redraw while executing macros
set linebreak             " Line break
set number                " Always show number-row
set ruler                 " Always show current position
set shiftwidth=2          " Number of spaces to use when indenting
set showmatch             " Show matching brackets when text indicator is over them
set smartcase             " When searching try to be smart about cases
set softtabstop=2         " Magic derp
set tabstop=2             " The amount of spaces a tab should be
set viminfo^=%            " Remember info about open buffers on close

" Highlight pattern dangling spaces,
" :highlight ExtraWhitespace ctermbg=darkgreen guibg=lightgreen
" :match ExtraWhitespace /\s\+$\| \+\ze\t/

" Return to last edit position when opening files,
"autocmd BufReadPost *
"   \ if line("'\"") > 0 && line("'\"") <= line("$") |
"   \   exe "normal! g`\"" |
"   \ endif

" Some magic,
augroup configgroup
  autocmd!
  autocmd BufWritePre * :call StripTrailingWhitespaces()
  autocmd BufEnter Makefile setlocal noexpandtab
augroup END

" Playing with themes,
colorscheme badwolf

" Make the gutters darker than the background.
let g:badwolf_darkgutter = 1

" Make the tab line much lighter than the background.
let g:badwolf_tabline = 3

" Turn on CSS properties highlighting
let g:badwolf_css_props_highlight = 1

" Tabs
highlight SpecialKey ctermfg=red
set list
set listchars=tab:..,trail:_,extends:>,precedes:<,nbsp:~

" Shortcut for visual block when ctrl+v is used by something else
command! Vb execute "normal! \<C-v>"

" Vertical bar
highlight ColorColumn ctermbg=darkred guibg=red
set colorcolumn=80

"
" Functions
"
" Removes dangling spaces, called on buffer write in the autogroup above.
function! StripTrailingWhitespaces()
    " save last search & cursor position
    let _s=@/
    let l = line(".")
    let c = col(".")
    %s/\s\+$//e
    let @/=_s
    call cursor(l, c)
endfunction
