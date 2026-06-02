# bash completion for nm-cli
#
# Completions are produced dynamically by the tool itself: this function
# re-invokes `nm-cli <words-so-far> --bash-completions`, which clingon answers
# with the sub-commands and options valid at that point on the command line.
#
# Install (any one of):
#   * copy this file to /etc/bash_completion.d/    (loaded automatically)
#   * copy to /usr/share/bash-completion/completions/nm-cli
#   * source it from your ~/.bashrc:  source /path/to/nm-cli.bash
#
# Requires the `bash-completion` package (for the _init_completion helper).

_nm_cli_completions() {
    local cur prev words cword
    _init_completion -s || return

    local _suggestions
    _suggestions=$("${words[@]:0:${cword}}" --bash-completions 2>/dev/null)
    local _options _sub_commands
    _options=$(grep -E '^-' <<<"${_suggestions}")
    _sub_commands=$(grep -v -E '^-' <<<"${_suggestions}")

    if [[ "${cur}" == "-"* ]]; then
        COMPREPLY=( $(compgen -W "${_options}" -- "${cur}") )
    else
        COMPREPLY=( $(compgen -W "${_sub_commands}" -- "${cur}") )
    fi
}

complete -o bashdefault \
         -o default \
         -o nospace \
         -F _nm_cli_completions nm-cli
