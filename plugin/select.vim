"""" Fuzzy select file/buffer/MRU/etc
"" Author: Maxim Kim <habamax@gmail.com>

" TODO: Popup windows? Probably.

if exists('g:loaded_select') || !exists("*matchfuzzypos") || !exists("*prompt_getprompt")
    finish
endif
let g:loaded_select = 1

command! -nargs=* -complete=customlist,select#command_complete Select call select#do(<f-args>)

nnoremap <silent> <Plug>(SelectFile) :Select file<CR>
nnoremap <silent> <Plug>(SelectProjectFile) :Select projectfile<CR>
nnoremap <silent> <Plug>(SelectProject) :Select project<CR>
nnoremap <silent> <Plug>(SelectBuffer) :Select buffer<CR>
nnoremap <silent> <Plug>(SelectMRU) :Select mru<CR>
nnoremap <silent> <Plug>(SelectCmd) :Select command<CR>
nnoremap <silent> <Plug>(SelectColors) :Select colors<CR>
nnoremap <silent> <Plug>(SelectHelp) :Select help<CR>
