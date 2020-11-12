let s:state = {}

"" Merge global defined select_info
call extend(select#def#get(), get(g:, "select_info", {}), "force")

let s:select = {}


"""
""" Entry point
"""
func! select#do(type, ...) abort
    "" Global select_info might be updated in the current vim session.
    "" Merge them with default
    call extend(select#def#get(), get(g:, "select_info", {}), "force")

    "" Always start with default and add buffer local select_info
    let s:select = select#def#get()->deepcopy()
    call extend(s:select, get(b:, "select_info", {}), "force")

    if !empty(a:type)
        if index(s:select->keys(), a:type) == -1
            echomsg a:type.." is not supported!"
            return
        endif
        let s:state.type = a:type
    else
        let s:state.type = 'file'
    endif

    try
        " Global settings change -- they would be restored when Select window is
        " closed.
        let s:state.laststatus = &laststatus
        let s:state.showmode = &showmode
        let s:state.ruler = &ruler

        " ESC is setup to exit Select windows but there are keys that
        " produce escape sequences -- <Left>, <Right>, etc. And if you press
        " them you end up messing a buffer, e.g. <Left> is a OD, you press
        " <ESC> it closes Select window, Open a new line in a current buffer and
        " add D char there.
        " To fix it I remapped some of those escape sequences but then <ESC>
        " doesn't close Select windows "immediatly" due to timeoutlen setting...
        " So I set it to some small value on Select window open and restore it
        " on Select window close.
        " FIXME: refactor when vim9 is out
        if !has('patch-8.2.1978')
            let s:state.timeoutlen = &timeoutlen
            set timeoutlen=10
        endif

        if a:0 == 1 && !empty(a:1)
            let s:state.path = s:normalize_path(fnamemodify(expand(a:1), ":p"))
        elseif a:type == 'file'
            let s:state.path = s:normalize_path(expand("%:p:h")..'/')
        else
            let s:state.path = s:normalize_path(getcwd()..'/')
        endif

        let s:state.stl_progress = ''
        let s:state.init_buf = {"bufnr": bufnr(), "winid": winnr()->win_getid()}
        let s:state.max_height = get(g:, "select_max_height", &lines/4)
        let s:state.max_buffer_items = get(g:, "select_max_buffer_items", 1000)
        let s:state.max_total_items = get(g:, "select_max_total_items", 50000)
        let s:state.result_buf = s:create_result_buf()
        let s:state.prompt_buf = s:create_prompt_buf()
        let s:state.cached_items = []
        let s:state.job_started = v:false
        if s:state->has_key("job")
            unlet s:state.job
        endif
        call s:update_results()
        startinsert!
    catch /.*/
        echomsg v:exception
        call s:close()
    endtry
endfunc



"""
""" Data handling
"""
func! s:update_results() abort
    if bufwinnr(s:state.result_buf.bufnr) == -1
        return
    endif

    if empty(s:state.cached_items)
        if type(s:select[s:state.type].data) == v:t_func
            let s:state.cached_items = s:select[s:state.type].data(s:state.path, s:state.init_buf)
        elseif !s:state.job_started && !s:state->has_key('job') && type(s:select[s:state.type].data) == v:t_dict
            if type(s:select[s:state.type].data["job"]) == v:t_string
                let cmd = s:select[s:state.type].data["job"]
            elseif type(s:select[s:state.type].data["job"]) == v:t_func
                let cmd = s:select[s:state.type].data["job"](s:state.path, s:state.init_buf)
            else
                return
            endif

            let s:state.job = job_start(cmd, {
                        \ "out_cb": "select#job_out",
                        \ "close_cb": "select#job_close",
                        \ "cwd": s:state.path})


            if job_status(s:state.job) != 'fail'
                let s:state.job_started = v:true
            endif
        endif
    endif

    let items = []
    let highlights = []

    let input = s:get_prompt_value()

    if input !~ '^\s*$'
        let [items, highlights] = matchfuzzypos(s:state.cached_items, input)
        let matched_items_cnt = len(items)
        let items = items[0 : s:state.max_buffer_items]
    else
        let matched_items_cnt = len(s:state.cached_items)
        let items = s:state.cached_items[0 : s:state.max_buffer_items]
    endif

    let s:state.stl_progress = printf(" %s/%s", matched_items_cnt, len(s:state.cached_items))
    call win_execute(s:state.result_buf.winid, 'redrawstatus')

    call setbufline(s:state.result_buf.bufnr, 1, items)
    silent call deletebufline(s:state.result_buf.bufnr, len(items) + 1, "$")

    if !empty(highlights)
        let top = min([50, len(items)])
        for bufline in range(1, top)
            let item = items[bufline - 1]
            for pos in highlights[bufline - 1]
                let col = byteidx(item, pos)
                let length = len(item[pos])
                call prop_add(bufline, col + 1, {'length': length, 'type': 'select_highlight', 'bufnr': s:state.result_buf.bufnr})
            endfor
        endfor
    endif
endfunc


func! select#job_out(channel, msg) abort
    if len(s:state.cached_items) < s:state.max_total_items
        " transform msg if data transform_output lambda exists
        if s:func_exists('data', 'transform_output')
            call add(s:state.cached_items, s:func('data', 'transform_output', a:msg))
        else
            call add(s:state.cached_items, a:msg)
        endif
    elseif s:state->has_key("job")
        call job_stop(s:state.job)
        unlet s:state.job
    endif

    if s:state->has_key("job") && job_status(s:state.job) == "run"
        call s:update_results()
    endif
endfunc


func! select#job_close(channel) abort
    call s:update_results()
endfunc


func! s:close() abort
    try
        call win_gotoid(s:state.init_buf.winid)
        call win_execute(s:state.result_buf.winid, 'quit!', 1)
        call win_execute(s:state.prompt_buf.winid, 'quit!', 1)
        if job_status(s:state.job) == "run"
            call job_stop(s:state.job)
        endif
    catch
    finally
        if s:state->has_key('job')
            unlet s:state.job
        endif
        let s:state.cached_items = []
        let &laststatus = s:state.laststatus
        let &showmode = s:state.showmode
        let &ruler = s:state.ruler
        " FIXME: refactor when vim9 is out
        if !has('patch-8.2.1978')
            let &timeoutlen = s:state.timeoutlen
        endif
    endtry
endfunc



"""
""" Buffer setup
"""
func! s:create_prompt_buf() abort
    let bufnr = s:prepare_buffer('prompt')
    call s:setup_prompt_mappings()
    call s:setup_prompt_autocommands()

    return {"bufnr": bufnr, "winid": bufnr->bufwinid()}
endfunc


func! s:create_result_buf() abort
    let bufnr = s:prepare_buffer('result')
    return {"bufnr": bufnr, "winid": bufnr->bufwinid()}
endfunc


func! s:prepare_buffer(type)
    if s:state->has_key(a:type.."_buf")
        let bufnr = s:state[a:type.."_buf"].bufnr
    else
        let bufnr = bufnr(tempname(), 1)
    endif
    exe "silent noautocmd botright sbuffer "..bufnr
    if a:type == "prompt"
        resize 1
        setlocal buftype=prompt
        set filetype=selectprompt
        setlocal nocursorline

        if s:select[s:state.type]->has_key("prompt")
            let prompt = s:select[s:state.type].prompt
        else
            let prompt = '> '
        endif
        call prompt_setprompt(bufnr, prompt)
        hi def link SelectPrompt PreProc
        exe printf("syn match SelectPrompt '^%s'", escape(prompt, '*#%^\\'))
    elseif a:type == 'result'
        exe printf('resize %d', s:state.max_height)
        setlocal buftype=nofile
        set filetype=selectresults
        setlocal statusline=%#Statusline#%{select#statusline_type()}%=%{select#statusline_progress()}
        setlocal cursorline
        setlocal noruler
        setlocal laststatus=0
        setlocal noshowmode
        if s:select[s:state.type]->has_key("highlight")
            " highlights could be generated by a lambda func.
            " no checks for the structure here... yet.
            if type(s:select[s:state.type].highlight) == v:t_func
                let highlights = s:select[s:state.type].highlight()
            elseif type(s:select[s:state.type].highlight) == v:t_dict
                let highlights = s:select[s:state.type].highlight
            endif
            if exists("highlights")
                for [hl_type, hl_params] in items(highlights)
                    exe printf("syn match Select%s '%s'", hl_type, hl_params[0])
                    exe printf("hi def link Select%s %s", hl_type, hl_params[1])
                endfor
            endif
        endif
        hi def link SelectMatched Statement
        try
            call prop_type_add('select_highlight', { 'highlight': 'SelectMatched', 'bufnr': bufnr })
        catch
        endtry
    endif
    setlocal nobuflisted
    setlocal bufhidden=delete
    setlocal noswapfile
    setlocal noundofile
    setlocal nospell
    setlocal nocursorcolumn
    setlocal nowrap
    setlocal nonumber norelativenumber
    setlocal nolist
    setlocal tw=0
    setlocal winfixheight
    abc <buffer>
    return bufnr
endfunc


func! s:setup_prompt_mappings() abort
    " check if <Cmd> exists
    if has('patch-8.2.1978')
        inoremap <silent><buffer> <CR> <Cmd>call <SID>on_select()<CR>
        inoremap <silent><buffer> <S-CR> <Cmd>call <SID>on_select('action2')<CR>
        inoremap <silent><buffer> <C-S> <Cmd>call <SID>on_select('action2')<CR>
        inoremap <silent><buffer> <C-V> <Cmd>call <SID>on_select('action3')<CR>
        inoremap <silent><buffer> <C-T> <Cmd>call <SID>on_select('action4')<CR>
        inoremap <silent><buffer> <C-j> <Cmd>call <SID>on_select('action_new')<CR>
        inoremap <silent><buffer> <ESC> <Cmd>call <SID>on_cancel()<CR>
        inoremap <silent><buffer> <C-c> <Cmd>call <SID>on_cancel()<CR>
        inoremap <silent><buffer> <TAB> <Cmd>call <SID>on_next_maybe()<CR>
        inoremap <silent><buffer> <S-TAB> <Cmd>call <SID>on_prev()<CR>
        inoremap <silent><buffer> <C-n> <Cmd>call <SID>on_next()<CR>
        inoremap <silent><buffer> <C-p> <Cmd>call <SID>on_prev()<CR>
        inoremap <silent><buffer> <Down> <Cmd>call <SID>on_next()<CR>
        inoremap <silent><buffer> <Up> <Cmd>call <SID>on_prev()<CR>
        inoremap <silent><buffer> <PageDown> <Cmd>call <SID>on_next_page()<CR>
        inoremap <silent><buffer> <PageUp> <Cmd>call <SID>on_prev_page()<CR>
        " update results in function
        inoremap <silent><buffer> <BS> <Cmd>call <SID>on_backspace(v:true)<CR><BS>
    else
        " FIXME: remove when vim9 is out
        inoremap <silent><buffer> <CR> <ESC>:call <SID>on_select()<CR>
        inoremap <silent><buffer> <S-CR> <ESC>:call <SID>on_select('action2')<CR>
        inoremap <silent><buffer> <C-S> <ESC>:call <SID>on_select('action2')<CR>
        inoremap <silent><buffer> <C-V> <ESC>:call <SID>on_select('action3')<CR>
        inoremap <silent><buffer> <C-T> <ESC>:call <SID>on_select('action4')<CR>
        inoremap <silent><buffer> <C-j> <ESC>:call <SID>on_select('action_new')<CR>
        inoremap <silent><buffer> <ESC> <ESC>:call <SID>on_cancel()<CR>
        inoremap <silent><buffer> <C-c> <ESC>:call <SID>on_cancel()<CR>
        inoremap <silent><buffer> <TAB> <ESC>:call <SID>on_next_maybe()<CR>
        inoremap <silent><buffer> <S-TAB> <ESC>:call <SID>on_prev()<CR>
        inoremap <silent><buffer> <C-n> <ESC>:call <SID>on_next()<CR>
        inoremap <silent><buffer> <C-p> <ESC>:call <SID>on_prev()<CR>
        inoremap <silent><buffer> <Down> <ESC>:call <SID>on_next()<CR>
        inoremap <silent><buffer> <Up> <ESC>:call <SID>on_prev()<CR>
        inoremap <silent><buffer> <PageDown> <ESC>:call <SID>on_next_page()<CR>
        inoremap <silent><buffer> <PageUp> <ESC>:call <SID>on_prev_page()<CR>
        " Can't update results in function, trigger TextChangedI event to
        " update...
        " FIXME: refactor when vim9 is out.
        inoremap <expr><silent><buffer> <BS> <SID>on_backspace(v:false) .. "\<Space>\<BS>\<BS>"

        inoremap <silent><buffer> <ESC>OD <Left>
        inoremap <silent><buffer> <ESC>OC <Right>
        imap <silent><buffer> <ESC>OA <Up>
        imap <silent><buffer> <ESC>OB <Down>
        imap <silent><buffer> <ESC>[Z <S-Tab>
    endif

    inoremap <silent><buffer> <C-B> <Left>
    inoremap <silent><buffer> <C-F> <Right>
    inoremap <silent><buffer> <C-A> <Home>
    inoremap <silent><buffer> <C-E> <End>
    inoremap <silent><buffer> <C-D> <Delete>

endfunc


func! s:setup_prompt_autocommands() abort
    augroup prompt | au!
        au TextChangedI <buffer> call s:update_results()
        au BufLeave <buffer> call <sid>close()
    augroup END
endfunc


func! select#statusline_progress() abort
    return s:state.stl_progress
endfunc


func! select#statusline_type() abort
    if s:state.type == 'file' || s:state.type == 'projectfile'
        return "["..s:state.path.."]"
    else
        return "["..s:state.type.."]"
    endif
endfunc



"""
""" Event handlers
"""
func! s:on_select(...) abort
    if a:0 && a:1 == 'action_new'
        let current_res = s:get_prompt_value()
    else
        let current_res = s:get_current_result()
    endif

    " handle "empty" sink
    " E.g. for Select file it would create a new file from the prompt value.
    if empty(current_res)
        if s:func_exists("sink", "empty")
            let current_res = s:func("sink", "empty", s:get_prompt_value())
        else
            startinsert!
            return
        endif
    endif

    " handle special cases (E.g. Select file on a directory should visit it
    " instead of opening
    if s:func_exists("sink", "special")
        if s:func("sink", "special", s:state, current_res)
            call s:update_results()
            startinsert!
            return
        endif
    endif

    " apply transform
    if s:func_exists("sink", "transform")
        let current_res = s:func("sink", "transform", s:state.path, current_res)
    endif

    " do nothing if action was specified and 
    " sink is either a string or sink is a dict without action provided
    if a:0 == 1 && !s:action_exists(a:1)
        startinsert!
        return
    endif

    call s:close()

    " set default action
    if a:0 == 0
        let action = 'action'
    else
        let action = a:1
    endif

    " run the action
    if s:func_exists("sink", action)
        call s:func("sink", action, current_res)
    elseif type(s:select[s:state.type]["sink"]) == v:t_string
        exe printf(s:select[s:state.type]["sink"], current_res)
    else
        exe printf(s:select[s:state.type]["sink"][action], current_res)
    endif
endfunc


func! s:on_cancel() abort
    call s:close()
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
    call s:on_next(s:state.max_height - 1)
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
    call s:on_prev(s:state.max_height - 1)
endfunc


func! s:on_backspace(update_res) abort
    if s:state.type == 'file' && empty(s:get_prompt_value())
        let parent_path = fnamemodify(s:state.path, ":p:h:h")
        if parent_path != s:state.path
            let s:state.path = substitute(parent_path..'/', '[/\\]\+', '/', 'g')
            let s:state.cached_items = []
            if a:update_res
                call s:update_results()
            endif
        endif
    endif
    return ''
endfunc

" func! s:on_backspace() abort
"     if s:state.type == 'file' && empty(s:get_prompt_value())
"         let parent_path = fnamemodify(s:state.path, ":p:h:h")
"         if parent_path != s:state.path
"             let s:state.path = substitute(parent_path..'/', '[/\\]\+', '/', 'g')
"             let s:state.cached_items = []
"             " Indirectly update results buffer -- you can't do it directly by
"             " calling s:update_results or trigger TextChangedI event with
"             " doautocmd...
"             " But you can trigger TextChangedI event inputing "empty result"
"             " text - Space and Backspace.
"             return " \<BS>"
"         endif
"     else
"         return "\<BS>"
"     endif
" endfunc


"""
""" Helpers
"""
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
    if bufwinnr(s:state.prompt_buf.bufnr) != -1
        let result = strcharpart(s:state.prompt_buf.bufnr->getbufline('$')[0], strchars(s:state.prompt_buf.bufnr->prompt_getprompt()))
    else
        let result = ''
    endif
    return result
endfunc


"" Normalize path separators
func! s:normalize_path(path) abort
    return substitute(a:path, '\\\+', '/', 'g')
endfunc


"" Check if lambda func exists for the given type and name
func! s:func_exists(type, name)
    return type(s:select[s:state.type][a:type]) == v:t_dict
                \ && s:select[s:state.type][a:type]->has_key(a:name)
                \ && type(s:select[s:state.type][a:type][a:name]) == v:t_func
endfunc


"" Call lambda function for a given type and name
func! s:func(type, name, ...)
    return call(s:select[s:state.type][a:type][a:name], a:000)
endfunc


"" Check if the action exists for the current Select type.
func! s:action_exists(action)
    let result = type(s:select[s:state.type]["sink"]) == v:t_dict
    let result = result && s:select[s:state.type]["sink"]->has_key(a:action)
    return result
endfunc


"""
""" Command completion
"""
func! select#command_complete(A,L,P)
    let cmd_parts = split(a:L, '\W\+', 1)
    " Complete subcommand
    if len(cmd_parts) <= 2
        if empty(a:A)
            return select#def#get()->keys()
        else
            return select#def#get()->keys()->matchfuzzy(a:A)
        endif
    elseif len(cmd_parts) > 2
        " Complete directory
        return map(getcompletion(a:A, 'dir'), {_, v -> fnameescape(v)})
    endif
endfunc
