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

" Handle backups nicely
set backup
if !isdirectory($HOME."/.cache/.vim/")
  silent! execute "!mkdir -p ~/.cache/.vim/"
endif
set backupdir=~/.cache/.vim//
set directory=~/.cache/.vim//
set undodir=~/.cache/.vim//
set writebackup
au BufWritePre * let &bex = '@' . strftime("%F.%H.%M")

" Enable to have automatic purging:w
"silent execute '!find $HOME/.vimtmp/backup -type f -mtime +7 -delete'

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
