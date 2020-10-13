let s:select_types = ["file", "buffer", "colors", "mru", "command"]

let s:state = {}

let s:sink = {}
let s:sink.file = "edit %s"
let s:sink.buffer = "buffer %s"
let s:sink.colors = "colorscheme %s"
let s:sink.command = ":%s"
let s:sink.mru = "edit %s"
let s:sink = extend(s:sink, get(g:, "select_sink", {}), "force")

let s:runner = {}
let s:runner.file = {->
            \  map(readdirex(s:state.path, {d -> d.type == 'dir'}), {k,v -> v.type == "dir" ? v.name..'/' : v.name})
            \+ map(readdirex(s:state.path, {d -> d.type != 'dir'}), {_,v -> v.name})
            \ }
let s:runner.buffer = {-> getcompletion('', 'buffer')}
let s:runner.colors = {-> getcompletion('', 'color')}
let s:runner.command = {-> getcompletion('', 'command')}
let s:runner.mru = {-> v:oldfiles}
let s:runner = extend(s:runner, get(g:, "select_runner", {}), "force")


func! select#do(type, ...) abort
    let s:state = {}
    if !empty(a:type)
        if index(s:select_types, a:type) == -1
            echomsg a:type.." is not supported!"
            return
        endif
        let s:state.type = a:type
    else
        let s:state.type = 'file'
    endif
    try
        let s:state.laststatus = &laststatus
        let s:state.showmode = &showmode
        let s:state.ruler = &ruler

        if a:type == 'file' && a:0 == 1 && !empty(a:1)
            let s:state.path = simplify(expand(a:1)..'/')
        else
            let s:state.path = simplify(expand("%:p:h")..'/')
        endif

        let s:state.maxheight = &lines/3
        let s:state.init_buf = {"bufnr": bufnr(), "winid": winnr()->win_getid()}
        let s:state.result_buf = s:create_result_buf()
        let s:state.prompt_buf = s:create_prompt_buf()
        let s:state.cached_items = []
        startinsert!
    catch /.*/
        echom v:exception
        call s:close()
    endtry
endfunc


func! s:create_prompt_buf() abort
    call s:prepare_buffer('prompt')
    call s:add_prompt_mappings()
    call s:add_prompt_autocommands()

    return {"bufnr": bufnr(), "winid": winnr()->win_getid()}
endfunc


func! s:create_result_buf() abort
    call s:prepare_buffer('result')
    return {"bufnr": bufnr(), "winid": winnr()->win_getid()}
endfunc


func! s:prepare_buffer(type)
    silent noautocmd keepalt botright 1new
    if a:type == "prompt"
        setlocal buftype=prompt
        setlocal nocursorline
        set filetype=selectprompt
    elseif a:type == 'result'
        exe printf("silent file [select %s]", s:state.type)
        set filetype=selectresults
        setlocal buftype=nofile
        setlocal cursorline
        setlocal noruler
        setlocal laststatus=0
        setlocal noshowmode
        if s:state.type == 'file'
            syn match SelectDirectory '^.*/$'
            hi def link SelectDirectory Directory
        else
            syn match SelectDirectoryPrefix '^.*[/\\]\ze.*$'
            hi def link SelectDirectoryPrefix Comment
        endif
        hi def link SelectMatched Statement
        call prop_type_add('highlight', { 'highlight': 'SelectMatched', 'bufnr': bufnr() })
    endif
    setlocal bufhidden=wipe
    setlocal noundofile
    setlocal nospell
    setlocal nobuflisted
    setlocal nocursorcolumn
    setlocal nowrap
    setlocal nonumber norelativenumber
    setlocal nolist
    setlocal noswapfile
    setlocal tw=0
    setlocal winfixheight
    abc <buffer>
endfunc


func! s:close() abort
    try
        call win_execute(s:state.result_buf.winid, "quit!", 1)
        call win_execute(s:state.prompt_buf.winid, "quit!", 1)
    catch
    finally
        call win_gotoid(s:state.init_buf.winid)
        let &laststatus = s:state.laststatus
        let &showmode = s:state.showmode
        let &ruler = s:state.ruler
    endtry
endfunc

func! s:on_cancel() abort
    call s:close()
endfunc


func! s:on_select() abort
    let current_res = s:get_current_result()

    if empty(current_res)
        startinsert!
        return
    endif

    if s:state.type == 'file'
        let current_res = fnameescape(simplify(s:state.path..current_res))
        if current_res =~ '/$'
            let s:state.path = current_res
            call setbufline(s:state.prompt_buf.bufnr, '$', '')
            let s:state.cached_items = []
            call s:on_update()
            startinsert!
            return
        endif
    endif

    call s:close()

    exe printf(s:sink[s:state.type], current_res)
endfunc


func! s:on_update() abort
    call win_execute(s:state.result_buf.winid, "silent %delete_", 1)
    call s:update_status()

    let input = s:get_prompt_value()

    if empty(s:state.cached_items)
        let s:state.cached_items = s:runner[s:state.type]()
    endif
    let items = s:state.cached_items

    let highlights = []

    if input !~ '^\s*$'
        let [items, highlights] = matchfuzzypos(items, input)
    endif

    call setbufline(s:state.result_buf.bufnr, 1, items)

    if !empty(highlights)
        let bufline = 1
        for hl in highlights
            for pos in hl
                call prop_add(bufline, pos + 1, {'length': 1, 'type': 'highlight', 'bufnr': s:state.result_buf.bufnr})
            endfor
        let bufline += 1
        endfor
    endif

    call win_execute(s:state.result_buf.winid, printf('resize %d', min([len(items), s:state.maxheight])))
    call win_execute(s:state.prompt_buf.winid, 'resize 1')
endfunc


func! s:on_next_maybe() abort
    if s:is_single_result()
        call s:on_select()
    else
        call s:on_next()
    endif
endfunc


func! s:on_next(...) abort
    let n = a:0 == 1 ? a:1 : 1
    if n == 1 && s:is_cursor_on_last_line()
        call win_execute(s:state.result_buf.winid, 'normal! gg', 1)
    else
        call win_execute(s:state.result_buf.winid, printf('normal! %sj', n), 1)
    endif
    startinsert!
endfunc


func! s:on_next_page() abort
    call s:on_next(s:state.maxheight - 1)
endfunc


func! s:on_backspace() abort
    if s:state.type == 'file' && empty(s:get_prompt_value())
        let parent_path = fnamemodify(s:state.path, ":p:h:h")
        if parent_path != s:state.path
            let s:state.path = substitute(parent_path..'/', '[/\\]\+', '/', 'g')
            let s:state.cached_items = []
            call s:on_update()
        endif
    else
        normal! x
    endif
    startinsert!
endfunc


func! s:on_prev(...) abort
    let n = a:0 == 1 ? a:1 : 1
    if n == 1 && s:is_cursor_on_first_line()
        call win_execute(s:state.result_buf.winid, 'normal! G', 1)
    else
        call win_execute(s:state.result_buf.winid, printf('normal! %sk', n), 1)
    endif
    startinsert!
endfunc


func! s:on_prev_page() abort
    call s:on_prev(s:state.maxheight - 1)
endfunc


func! s:get_current_result() abort
    let res_linenr = line('.', s:state.result_buf.winid)
    return getbufline(s:state.result_buf.bufnr, res_linenr)[0]
endfunc


func! s:is_single_result() abort
    let last_linenr = line('$', s:state.result_buf.winid)
    let last_line = getbufline(s:state.result_buf.bufnr, '$')[0]
    return last_linenr == 1 && last_line !~ '^\s*$'
endfunc


func! s:is_cursor_on_last_line() abort
    return line('$', s:state.result_buf.winid) == line('.', s:state.result_buf.winid)
endfunc


func! s:is_cursor_on_first_line() abort
    return 1 == line('.', s:state.result_buf.winid)
endfunc


func! s:get_prompt_value() abort
    return strcharpart(s:state.prompt_buf.bufnr->getbufline('$')[0], strchars(s:state.prompt_buf.bufnr->prompt_getprompt()))
endfunc


func! s:add_prompt_mappings() abort
    inoremap <silent><buffer> <CR> <ESC>:call <SID>on_select()<CR>
    inoremap <silent><buffer> <ESC> <ESC>:call <SID>on_cancel()<CR>
    inoremap <silent><buffer> <TAB> <ESC>:call <SID>on_next_maybe()<CR>
    inoremap <silent><buffer> <S-TAB> <ESC>:call <SID>on_prev<CR>
    inoremap <silent><buffer> <BS> <ESC>:call <SID>on_backspace()<CR>
    inoremap <silent><buffer> <C-n> <ESC>:call <SID>on_next()<CR>
    inoremap <silent><buffer> <C-p> <ESC>:call <SID>on_prev()<CR>
    inoremap <silent><buffer> <Down> <ESC>:call <SID>on_next()<CR>
    inoremap <silent><buffer> <Up> <ESC>:call <SID>on_prev()<CR>
    inoremap <silent><buffer> <PageDown> <ESC>:call <SID>on_next_page()<CR>
    inoremap <silent><buffer> <PageUp> <ESC>:call <SID>on_prev_page()<CR>
endfunc


func! s:add_prompt_autocommands() abort
    augroup prompt | au!
        au TextChangedI <buffer> call s:on_update()
    augroup END
endfunc


func! s:update_status() abort
    if s:state.type == 'file'
        call win_execute(s:state.result_buf.winid, printf('silent file [%s]', s:state.path), 1)
    endif
endfunc
