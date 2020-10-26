let s:state = {}


let s:select_def = {}
let s:select_def.file = {}
let s:select_def.projectfile = {}
let s:select_def.project = {}
let s:select_def.mru = {}
let s:select_def.buffer = {}
let s:select_def.colors = {}
let s:select_def.command = {}
let s:select_def.help = {}

let s:select_def.file.data = {->
            \  map(readdirex(s:state.path, {d -> d.type == 'dir'}), {k,v -> v.type == "dir" ? v.name..'/' : v.name})
            \+ map(readdirex(s:state.path, {d -> d.type != 'dir'}), {_,v -> v.name})
            \ }
let s:select_def.file.sink = {"transform": {p, v -> fnameescape(p..v)}, "action": "edit %s", "action2": "split %s", "action3": "vsplit %s", "action4": "tab split %s"}

if executable('fd')
    let s:select_def.projectfile.data = {"cmd": "fd --type f --hidden --follow --no-ignore-vcs --exclude .git"}
elseif executable('fdfind')
    let s:select_def.projectfile.data = {"cmd": "fdfind --type f --hidden --follow --no-ignore-vcs --exclude .git"}
elseif executable('rg')
    let s:select_def.projectfile.data = {"cmd": "rg --files --no-ignore-vcs --hidden --glob !.git"}
elseif !has("win32")
    let s:select_def.projectfile.data = {"cmd": "find -type f -not -path \"*/.git/*\""}
else
    let s:select_def.projectfile.data = ""
endif
let s:select_def.projectfile.sink = {"transform": {p, v -> fnameescape(p..v)}, "action": "edit %s", "action2": "split %s", "action3": "vsplit %s", "action4": "tab split %s"}

let s:select_def.mru.data = {-> filter(copy(v:oldfiles), {_,v -> v !~ 'Local[/\\]Temp[/\\].*tmp$' && v !~ '/tmp/.*'})}
let s:select_def.mru.sink = {"transform": {_, v -> fnameescape(v)}, "action": "edit %s", "action2": "split %s", "action3": "vsplit %s", "action4": "tab split %s"}

let s:select_def.buffer.data = {-> s:get_buffer_list()}
let s:select_def.buffer.sink = {"transform": {_, v -> matchstr(v, '^\s*\zs\d\+')}, "action": "buffer %s", "action2": "sbuffer %s", "action3": "vert sbuffer %s", "action4": "tab sbuffer %s"}

let s:select_def.colors.data = {-> s:get_colorscheme_list()}
let s:select_def.colors.sink = "colorscheme %s"

let s:select_def.command.data = {-> getcompletion('', 'command')}
let s:select_def.command.sink = {"action": {v -> feedkeys(':'..v, 'n')}}

let s:select_def.project.data = {-> s:get_project_list()}
let s:select_def.project.sink = {"action": "Select projectfile %s", "action2": "Select file %s"}

let s:select_def.help.data = {"cmd": {-> s:get_helptags()}}
let s:select_def.help.sink = "help %s"


"" Merge global defined select_info
call extend(s:select_def, get(g:, "select_info", {}), "force")

let s:select = {}


func! select#do(type, ...) abort
    "" Global select_info might be updated in the current vim session.
    "" Merge them with default
    call extend(s:select_def, get(g:, "select_info", {}), "force")

    "" Always start with default and add buffer local select_info
    let s:select = s:select_def->deepcopy()
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
        let s:state.laststatus = &laststatus
        let s:state.showmode = &showmode
        let s:state.ruler = &ruler

        if a:0 == 1 && !empty(a:1)
            let s:state.path = s:normalize_path(fnamemodify(a:1, ":p"))
        elseif a:type == 'file'
            let s:state.path = s:normalize_path(expand("%:p:h")..'/')
        else
            let s:state.path = s:normalize_path(getcwd()..'/')
        endif

        let s:state.stl_progress = ''
        let s:state.init_buf = {"bufnr": bufnr(), "winid": winnr()->win_getid()}
        let s:state.max_height = &lines/3
        let s:state.max_buffer_items = get(g:, "select_max_buffer_items", 1000)
        let s:state.max_total_items = get(g:, "select_max_total_items", 30000)
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
    if len(s:state.cached_items) < s:state.max_total_items
        call add(s:state.cached_items, a:msg)
    else
        call job_stop(s:state.job)
    endif

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
            return s:select_def->keys()
        else
            return s:select_def->keys()->matchfuzzy(a:A)
        endif
    elseif len(cmd_parts) > 2
        " Complete directory
        return map(getcompletion(a:A, 'dir'), {_, v -> fnameescape(v)})
    endif
endfunc


func! select#statusline_type() abort
    if s:state.type == 'file' || s:state.type == 'projectfile'
        return "["..s:state.path.."]"
    else
        return "["..s:state.type.."]"
    endif
endfunc


func! select#statusline_progress() abort
    return s:state.stl_progress
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
        setlocal statusline=%#Statusline#%{select#statusline_type()}%=%#StatuslineNC#%{select#statusline_progress()}
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
        hi def link SelectMatched String
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
        call win_execute(s:state.result_buf.winid, 'quit!', 1)
        call win_execute(s:state.prompt_buf.winid, 'quit!', 1)
        if s:state.job != v:null && job_status(s:state.job) == "run"
            call job_stop(s:state.job)
        endif
    catch
    finally
        let s:state.job = v:null
        let s:state.cached_items = []
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

    " file is a special case to be able to go down/up directory structure
    if s:state.type == 'file' && current_res =~ '/$'
        let s:state.path ..= current_res
        call setbufline(s:state.prompt_buf.bufnr, '$', '')
        let s:state.cached_items = []
        call s:update_results()
        startinsert!
        return
    endif

    " projectfile is a special case to persist project once file was selected
    if s:state.type == 'projectfile'
        call s:add_project(s:state.path)
        call s:save_project_list()
    endif

    let cmd = {}
    if type(s:select[s:state.type].sink) == v:t_string
        " do nothing if action was specified and sink is a string
        if a:0 == 1
            startinsert!
            return
        else
            let cmd.s = s:select[s:state.type].sink
        endif
    elseif type(s:select[s:state.type].sink) == v:t_dict
        " do nothing if action was specified and sink is a dict without
        " a corresponding action key
        if a:0 == 1
            if !s:select[s:state.type].sink->has_key(a:1)
                startinsert!
                return
            else
                let cmd.s = s:select[s:state.type].sink[a:1]
            endif
        else
            let cmd.s = s:select[s:state.type].sink['action']
        endif
        if s:select[s:state.type].sink->has_key("transform")
            let current_res = s:select[s:state.type].sink["transform"](s:state.path, current_res)
        endif
    endif

    call s:close()

    if type(cmd.s) == v:t_string
        exe printf(cmd.s, current_res)
    elseif type(cmd.s) == v:t_func
        call cmd.s(current_res)
    endif
endfunc


func! s:update_results() abort
    if empty(s:state.cached_items) && type(s:select[s:state.type].data) == v:t_func
        let s:state.cached_items = s:select[s:state.type].data(s:state.init_buf)
    elseif s:state.job == v:null && type(s:select[s:state.type].data) == v:t_dict
        if type(s:select[s:state.type].data["cmd"]) == v:t_string
            let cmd = s:select[s:state.type].data["cmd"]
        elseif type(s:select[s:state.type].data["cmd"]) == v:t_func
            let cmd = s:select[s:state.type].data["cmd"]()
        else
            return
        endif
        let s:state.job = job_start(cmd, {
                    \ "out_cb": "select#job_out",
                    \ "close_cb": "select#job_close",
                    \ "cwd": s:state.path})
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

    call setbufline(s:state.result_buf.bufnr, 1, items)
    silent call deletebufline(s:state.result_buf.bufnr, len(items) + 1, "$")

    if !empty(highlights)
        let top = min([50, len(items)])
        for bufline in range(1, top)
            for pos in highlights[bufline - 1]
                call prop_add(bufline, pos + 1, {'length': 1, 'type': 'select_highlight', 'bufnr': s:state.result_buf.bufnr})
            endfor
        endfor
    endif

    call win_execute(s:state.result_buf.winid, printf('resize %d', min([len(items), s:state.max_height])))
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
    call s:on_next(s:state.max_height - 1)
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
    call s:on_prev(s:state.max_height - 1)
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
    inoremap <silent><buffer> <S-CR> <ESC>:call <SID>on_select('action2')<CR>
    inoremap <silent><buffer> <C-S> <ESC>:call <SID>on_select('action2')<CR>
    inoremap <silent><buffer> <C-V> <ESC>:call <SID>on_select('action3')<CR>
    inoremap <silent><buffer> <C-T> <ESC>:call <SID>on_select('action4')<CR>
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


"" Buffer list is sorted by lastused time + 2 most recently used buffers
"" are exchanged/switched:
"" * second lastused is the first in the list
"" * first lastused is the second in the list
"" Thus you can easily switch between 2 buffers with :Select buffer and <CR>
func! s:get_buffer_list() abort
    let l:Sort = {a, b -> a.lastused == b.lastused ? 0 : a.lastused > b.lastused ? -1 : 1}
    let buflist = sort(getbufinfo({'buflisted': 1}), l:Sort)
    return map(buflist[1:1] + buflist[0:0] + buflist[2:], {k, v -> printf("%3d: %s", v.bufnr, (empty(v.name) ? "[No Name]" : s:shorten_bufname(v.name)))})
endfunc


"" Colorscheme list.
"" * remove current colorscheme name  from the list of all sorted colorschemes.
"" * put current colorscheme name on top of the colorscheme list.
"" Thus current colorscheme is initially preselected.
func! s:get_colorscheme_list() abort
    let colors_name = get(g:, "colors_name", "default")
    return [colors_name] + filter(getcompletion('', 'color'), {_, v -> v != colors_name})
endfunc


"" Project list.
"" List of current working directories where :Select projectfile was run.
func! s:get_project_list() abort
    if !s:state->has_key("projects")
        let s:state["projects"] = []
    endif
    try
        let fname = fnamemodify(expand("$MYVIMRC"), ":p:h").."/.selectprojects"
        let s:state["projects"] = readfile(fname)
    catch
    endtry
    return s:state["projects"]
endfunc


func! s:save_project_list() abort
    if !s:state->has_key("projects") || len(s:state["projects"]) == 0
        return
    endif
    try
        let fname = fnamemodify(expand("$MYVIMRC"), ":p:h").."/.selectprojects"
        call writefile(s:state["projects"], fname)
    catch
    endtry
endfunc


func! s:add_project(project) abort
    if !s:state->has_key("projects")
        let s:state["projects"] = s:get_project_list()
    endif
    let project = trim(a:project, "/", 2)
    let s:state["projects"] = [project] + filter(s:state["projects"], {_, v -> v != project})
endfunc


" List of all help tags/topics.
" Uses ripgrep.
func! s:get_helptags() abort
    let l:help = split(globpath(&runtimepath, 'doc/tags', 1), '\n')
    return 'rg ^[^[:space:]]+ -No --no-heading --no-filename '..join(map(l:help, {_,v -> fnameescape(v)}))
endfunc
