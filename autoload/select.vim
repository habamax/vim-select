let s:state = {}


let s:sink_def = {}
let s:sink_def.file = {"transform": {p, v -> fnameescape(p..v)}, "action": "edit %s", "action_split": "split %s", "action_vsplit": "vsplit %s"}
let s:sink_def.projectfile = {"transform": {p, v -> fnameescape(p..v)}, "action": "edit %s", "action_split": "split %s", "action_vsplit": "vsplit %s"}
let s:sink_def.mru = {"transform": {_, v -> fnameescape(v)}, "action": "edit %s", "action_split": "split %s", "action_vsplit": "vsplit %s"}
let s:sink_def.buffer = {"transform": {_, v -> matchstr(v, '^\s*\zs\d\+')}, "action": "buffer %s", "action_split": "sbuffer %s", "action_vsplit": "vert sbuffer %s"}
let s:sink_def.colors = "colorscheme %s"
let s:sink_def.command = ":%s"


let s:runner_def = {}
let s:runner_def.file = {->
            \  map(readdirex(s:state.path, {d -> d.type == 'dir'}), {k,v -> v.type == "dir" ? v.name..'/' : v.name})
            \+ map(readdirex(s:state.path, {d -> d.type != 'dir'}), {_,v -> v.name})
            \ }

if executable('rg')
    let s:runner_def.projectfile = {"cmd": "rg --files --no-ignore-vcs --hidden --glob !.git"}
elseif executable('fd')
    let s:runner_def.projectfile = {"cmd": "fd --type f --hidden --follow --no-ignore-vcs --exclude .git"}
elseif executable('fdfind')
    let s:runner_def.projectfile = {"cmd": "fdfind --type f --hidden --follow --no-ignore-vcs --exclude .git"}
else
    let s:runner_def.projectfile = ""
endif

let s:runner_def.buffer = {-> map(getbufinfo({'buflisted': 1}), {k, v -> printf("%3d: %s", v.bufnr, (empty(v.name) ? "[No Name]" : s:shorten_bufname(v.name)))})}
let s:runner_def.colors = {-> getcompletion('', 'color')}
let s:runner_def.command = {-> getcompletion('', 'command')}
let s:runner_def.mru = {-> filter(copy(v:oldfiles), {_,v -> v !~ 'Local[/\\]Temp[/\\].*tmp$' && v !~ '/tmp/.*'})}

"" Merge global defined runners and sinks
call extend(s:runner_def, get(g:, "select_runner", {}), "force")
call extend(s:sink_def, get(g:, "select_sink", {}), "force")

let s:runner = {}
let s:sink = {}


func! select#do(type, ...) abort
    "" Global runners and sinks might be updated in the current vim session.
    "" Merge them with default
    call extend(s:runner_def, get(g:, "select_runner", {}), "force")
    call extend(s:sink_def, get(g:, "select_sink", {}), "force")

    "" Always start with default and add buffer local runners and sinks
    let s:runner = s:runner_def->deepcopy()
    let s:sink = s:sink_def->deepcopy()
    call extend(s:runner, get(b:, "select_runner", {}), "force")
    call extend(s:sink, get(b:, "select_sink", {}), "force")

    if !empty(a:type)
        if index(s:runner->keys(), a:type) == -1
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

        if a:0 == 1 && !empty(a:1)
            let s:state.path = s:normalize_path(fnamemodify(a:1, "%:p")..'/')
        elseif a:type == 'file'
            let s:state.path = s:normalize_path(expand("%:p:h")..'/')
        else
            let s:state.path = s:normalize_path(getcwd()..'/')
        endif

        let s:state.init_buf = {"bufnr": bufnr(), "winid": winnr()->win_getid()}
        let s:state.maxheight = &lines/3
        let s:state.maxitems = 1000
        let s:state.result_buf = s:create_result_buf()
        let s:state.prompt_buf = s:create_prompt_buf()
        let s:state.cached_items = []
        let s:state.job = v:null
        startinsert!
    catch /.*/
        echom v:exception
        call s:close()
    endtry
endfunc


func! select#job_out(channel, msg) abort
    call add(s:state.cached_items, a:msg)
    if s:state.job != v:null && job_status(s:state.job) == "run"
        call s:update_results()
    endif
endfunc

func! select#job_close(channel) abort
    if s:state.job != v:null
        call s:update_results()
    endif
endfunc


func! select#command_complete(A,L,P)
    let cmd_parts = split(a:L, '\W\+', 1)
    " Complete subcommand
    if len(cmd_parts) <= 2
        if empty(a:A)
            return s:runner_def->keys()
        else
            return s:runner_def->keys()->matchfuzzy(a:A)
        endif
    elseif len(cmd_parts) <=3
        " Complete directory
        return getcompletion(a:A, 'dir')
    endif
endfunc


func! select#update_statusline() abort
    if s:state.type == 'file' || s:state.type == 'projectfile'
        return "["..s:state.path.."]"
    else
        return "["..s:state.type.."]"
    endif
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
    if s:state->has_key(a:type.."_buf")
        let bufnr = s:state[a:type.."_buf"].bufnr
    else
        let bufnr = bufnr(tempname(), 1)
    endif
    exe "silent noautocmd botright sbuffer "..bufnr
    resize 1
    if a:type == "prompt"
        setlocal buftype=prompt
        set filetype=selectprompt
        setlocal nocursorline
    elseif a:type == 'result'
        setlocal buftype=nofile
        set filetype=selectresults
        setlocal statusline=%#Statusline#%{select#update_statusline()}
        setlocal cursorline
        setlocal noruler
        setlocal laststatus=0
        setlocal noshowmode
        if s:state.type == 'file'
            syn match SelectDirectory '^.*/$'
            hi def link SelectDirectory Directory
        else
            syn match SelectBufferNumber '^\(\s*\d\+:\)'
            syn match SelectDirectoryPrefix '\(\s*\d\+:\)\?\zs.*[/\\]\ze.*$'
            hi def link SelectDirectoryPrefix Comment
            hi def link SelectBufferNumber Identifier
        endif
        hi def link SelectMatched Statement
        try
            call prop_type_add('select_highlight', { 'highlight': 'SelectMatched', 'bufnr': bufnr() })
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
endfunc


func! s:close() abort
    try
        if s:state.job != v:null
            call job_stop(s:state.job)
            let s:state.job = v:null
        endif
        call win_execute(s:state.result_buf.winid, 'quit!', 1)
        call win_execute(s:state.prompt_buf.winid, 'quit!', 1)
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


func! s:on_select(...) abort
    let current_res = s:get_current_result()

    if empty(current_res)
        startinsert!
        return
    endif

    if s:state.type == 'file' && current_res =~ '/$'
        let s:state.path ..= current_res
        call setbufline(s:state.prompt_buf.bufnr, '$', '')
        let s:state.cached_items = []
        call s:update_results()
        startinsert!
        return
    endif

    call s:close()

    let cmd = {}
    if type(s:sink[s:state.type]) == v:t_string
        let cmd.s = s:sink[s:state.type]
    elseif type(s:sink[s:state.type]) == v:t_dict
        if a:0 == 1
            let cmd.s = s:sink[s:state.type][a:1]
        else
            let cmd.s = s:sink[s:state.type]['action']
        endif
        if s:sink[s:state.type]->has_key("transform")
            let current_res = s:sink[s:state.type]["transform"](s:state.path, current_res)
        endif
    endif

    if type(cmd.s) == v:t_string
        exe printf(cmd.s, current_res)
    elseif type(cmd.s) == v:t_func
        call cmd.s(current_res)
    endif
endfunc


func! s:update_results() abort
    if empty(s:state.cached_items) && type(s:runner[s:state.type]) == v:t_func
        let s:state.cached_items = s:runner[s:state.type]()
    elseif s:state.job == v:null && type(s:runner[s:state.type]) == v:t_dict
        let s:state.job = job_start(s:runner[s:state.type]["cmd"], {
                    \ "out_cb": "select#job_out",
                    \ "close_cb": "select#job_close",
                    \ "cwd": s:state.path})
    endif
    let items = s:state.cached_items

    let highlights = []

    let input = s:get_prompt_value()

    if input !~ '^\s*$'
        let [items, highlights] = matchfuzzypos(items, input)[0:s:state.maxitems]
    endif

    call setbufline(s:state.result_buf.bufnr, 1, items)
    silent call deletebufline(s:state.result_buf.bufnr, len(items) + 1, "$")

    if !empty(highlights)
        let top = min([200, len(highlights)])
        for bufline in range(1, top)
            for pos in highlights[bufline-1]
                call prop_add(bufline, pos + 1, {'length': 1, 'type': 'select_highlight', 'bufnr': s:state.result_buf.bufnr})
            endfor
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
            call s:update_results()
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
    inoremap <silent><buffer> <S-CR> <ESC>:call <SID>on_select('action_split')<CR>
    inoremap <silent><buffer> <C-S> <ESC>:call <SID>on_select('action_split')<CR>
    inoremap <silent><buffer> <C-V> <ESC>:call <SID>on_select('action_vsplit')<CR>
    inoremap <silent><buffer> <ESC> <ESC>:call <SID>on_cancel()<CR>
    inoremap <silent><buffer> <TAB> <ESC>:call <SID>on_next_maybe()<CR>
    inoremap <silent><buffer> <S-TAB> <ESC>:call <SID>on_prev()<CR>
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
        au TextChangedI <buffer> call s:update_results()
    augroup END
endfunc


func s:normalize_path(path) abort
    return substitute(a:path, '\\\+', '/', 'g')
endfunc


"" Naive but looks like it works
func! s:shorten_bufname(bname)
    let cwd = s:normalize_path(getcwd()..'/')
    let bname = s:normalize_path(a:bname)
    if strchars(cwd) > strchars(bname)
        return bname
    endif
    let res = ''
    for c in range(strchars(bname))
        if c > strchars(cwd) || bname->strcharpart(c, 1) != cwd->strcharpart(c, 1)
            let res .= bname->strcharpart(c, 1)
        endif
    endfor
    return res
endfunc
