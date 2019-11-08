" Enable syntax highlighting,
syntax on

" Enable file type plug,
filetype plugin on
filetype indent on

" Fast saving,
map qq :w!<cr>

" Toggle long lines highlighting,
map åå :call ShowLongLines()<cr>

" Toggle spell checking,
map ää :setlocal spell!<cr>

" Never do sudo vim again,
cmap w!! w !sudo tee %

" Not really sure,
scriptencoding utf-8

" Set some reasonable defaults
set autoindent            " Simple indent
set cmdheight=2           " Height of the command bar
set cursorline            " highlight current line
set encoding=utf-8        " Show files in utf8
set expandtab             " Inserts <softtabstop-nr-of-spaces> instead of tabs
set fileencoding=utf-8    " Save files in utf8
set guifont=Monospace\ 9  " Font in gui
set hls                   " Highlight matches
set hlsearch              " Highlight search results
set ic	                  "	Ignore case while searching
set incsearch             " Search while typing
set laststatus=2          " Always show the status line
set lazyredraw            " Don't redraw while executing macros (good performance)
set linebreak             " Line break
set magic                 " For regular expressions turn magic on
set mat=2                 " How many 10ths of a second to blink when matching brackets
set number                " Always show number-row
" set paste                 " Always paste mode
set ruler                 " Always show current position
set shiftwidth=2          " Number of spaces to use when indenting
set showmatch             " Show matching brackets when text indicator is over them
set smartcase             " When searching try to be smart about cases
set showcmd               " show command in bottom bar
set softtabstop=2         " Magic derp
set tabpagemax=50         " Maximum number of tabs allowed open
set tabstop=2             " The amount of spaces a tab should be
set viminfo^=%            " Remember info about open buffers on close
set wrap                  " Line break
set wildmenu              " visual auto complete for command menu
set backup
set writebackup
set backupdir^=$HOME/.cache//
set directory^=$HOME/.cache//
set undodir^=$HOME/.cache//

" Highlight pattern dangling spaces,
:highlight ExtraWhitespace ctermbg=darkgreen guibg=lightgreen
:match ExtraWhitespace /\s\+$\| \+\ze\t/

" Return to last edit position when opening files,
autocmd BufReadPost *
   \ if line("'\"") > 0 && line("'\"") <= line("$") |
   \   exe "normal! g`\"" |
   \ endif

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


"
" Functions
"
" Toggle red indicator at 80 chars
let s:color_column_toggle = 0
highlight ColorColumn ctermfg=red ctermbg=233

function! ShowLongLines()
    if s:color_column_toggle == 0
      let w:m1 = matchadd('ColorColumn', '\%81v')
      let s:color_column_toggle = 1
    else
      call matchdelete(w:m1)
      let s:color_column_toggle = 0
    endif
endfunction

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

" Call these at startup,
call ShowLongLines()
