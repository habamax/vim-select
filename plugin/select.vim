"""" Fuzzy select file/buffer/MRU/etc
"" Author: Maxim Kim <habamax@gmail.com>

" TODO: Search for all files in subdirectories (projectfile)
" TODO: Popup windows? Probably.

if exists('g:loaded_select') || !exists("*matchfuzzypos") || !exists("*prompt_getprompt")
    finish
endif
let g:loaded_select = 1

command! -nargs=? -complete=customlist,SelectTypeComplete Select call select#do(<q-args>)
command! -nargs=? -complete=dir SelectFile call select#do('file', <q-args>)
command! SelectBuffer silent call select#do('buffer')
command! SelectMRU silent call select#do('mru')
command! SelectCmd silent call select#do('command')
command! SelectColor silent call select#do('colors')

nnoremap <silent> <Plug>(SelectFile) :SelectFile<CR>
nnoremap <silent> <Plug>(SelectBuffer) :SelectBuffer<CR>
nnoremap <silent> <Plug>(SelectMRU) :SelectMRU<CR>
nnoremap <silent> <Plug>(SelectCmd) :SelectCmd<CR>
nnoremap <silent> <Plug>(SelectColors) :SelectColors<CR>

func! SelectTypeComplete(A,L,P)
    if empty(a:A)
        return s:select_types
    else
        return s:select_types->matchfuzzy(a:A)
    endif
endfunc
