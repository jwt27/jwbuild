#!/usr/bin/false

set -e
unset CDPATH
declare -A options
declare -A saved_vars
declare makefile_vars
declare -a submodules
declare -A submodule_args
declare -ra arguments=("$@")
readonly src="$(dirname "$(realpath "${BASH_SOURCE[1]}")")"
readonly generated_files='Makefile config.status cxxflags ldflags cxxdeps lddeps targets'

# Display a message.
msg() # [message]
{
	echo "$@" 1>&2
}

# Exit with an error message
fail() # [message]
{
	msg Error: "$@"
	exit 1
}

# Display a warning
warn() # [message]
{
	msg Warning: "$@"
}

for i in "${arguments[@]}"; do
	case "$i" in
	--*=*)
		i="${i#--}"
		var="${i%%=*}"
		value="${i#*=}"
		options[$var]="$value"
		;;
	--*)
		i="${i#--}"
		options[$i]=yes
		;;
	*=*)
		var="${i%%=*}"
		value="${i#*=}"
		eval "$var"="'$value'"
		export "$var"
		;;
	*)
		fail "invalid argument: $i"
		;;
	esac
done

# Logical NOT operator.
not() # <expression...>
{
	! "$@"
}

# Set the default value for a given option.
option_default() # <option_name> <value>
{
	if [[ -z "${options[$1]}" ]]; then
		options[$1]="$2"
	fi
}

# Parse boolean string and return as exit code.
test_bool() # <string>
{
	case "$1" in
	true)  return 0 ;;
	false) return 1 ;;
	y*)    return 0 ;;
	Y*)    return 0 ;;
	n*)    return 1 ;;
	N*)    return 1 ;;
	1)     return 0 ;;
	0)     return 1 ;;
	'')    return 1 ;;
	*)     fail "unrecognized boolean value $1" ;;
	esac
}

# Parse boolean option and return as exit code.
test_option() # <option_name>
{
	if test_bool "${options[$1]}"; then
		options[$1]=yes
		return 0
	else
		options[$1]=no
		return 1
	fi
}

# Add a string in front of variable
prepend() # <var_name> <string...>
{
	local -n ref=$1
	shift
	ref="$@ $ref"
}

# Add a submodule to be configured with the given arguments
add_submodule() # <relative_directory> [configure_args...]
{
	local dir=$1
	shift
	submodules+=($dir)
	submodule_args[$dir]="$@"
	mkdir -p $dir
	for i in $(cd $dir && $src/$dir/configure --query-vars); do
		saved_vars[$i]="${!i}"
		export $i
	done
}

# Save given environment variables, exit if --query-flags is given.
save_vars() # [variable_names...]
{
	makefile_vars="$@"
	for i in "$@"; do
		saved_vars[$i]="${!i}"
		export $i
	done
	if test_option query-vars; then
		echo ${!saved_vars[@]}
		exit
	fi
	msg "Configuring in $(pwd) ..."
}

# Return Windows-style path, if running in MinGW
winpath() # <path>
{
	case $(uname) in
	MINGW*) echo "$(cygpath -w "$@")" ;;
	*) echo "$@" ;;
	esac
}

# Check if a program is installed
have_program() # <program_name>
{
	which "$@" 2>&1 > /dev/null
}

# Check if all given programs are installed
check_programs() # <program_names...>
{
	for i in "$@"; do
		if ! have_program $i; then
			fail "$i not found"
		fi
	done
}

# Compile input with given cxxflags
compile() # [extra_flags...]
{
	set +e
	$CXX $CXXFLAGS "$@" -x c++ -c -o tmpfile - > /dev/null
	local status=$?
	set -e
	rm -f tmpfile
	return $status
}

# Compile and link input with given cxxflags
compile_exe() # [extra_flags...]
{
	set +e
	$CXX $CXXFLAGS "$@" -x c++ -o tmpfile $LDFLAGS - > /dev/null
	local status=$?
	set -e
	rm -f tmpfile
	return $status
}

# Compile without displaying compiler output
compile_silent() # [extra_flags...]
{
	compile "$@" > /dev/null 2>&1
}

# Compile and link without displaying compiler output
compile_exe_silent() # [extra_flags...]
{
	compile_exe "$@" > /dev/null 2>&1
}

# Check if the compiler understands given cxxflags
check_compiler() # [cxxflags_to_test...]
{
	echo | compile || fail "compiler does not work"
	for i in "$@"; do
		echo | compile $i || fail "compiler does not understand $i"
	done
}

# Configure submodules given earlier with add_submodule
configure_submodules() #
{
	local args=
	for a in "${!options[@]}"; do
		[[ -z "${options[$a]}" ]] && continue
		args+=" --$a=${options[$a]}"
	done
	for sub in "${submodules[@]}"; do
		( cd "$sub" && "$src/$sub/configure" $args ${submodule_args[$sub]} )
	done
}

# Generate config.status
save_config() #
{
	if test_option help; then
		fail "no help message!"
	fi

	rm -f $generated_files

	{
		echo '#!/usr/bin/env bash'
		for i in "${!saved_vars[@]}"; do
			echo "export $i='${saved_vars[$i]}'"
		done
		for i in exec "$0" "${arguments[@]}"; do
			echo -n "'$i' "
		done
		echo
	} >> config.status
	chmod +x config.status
}

# Prepend the given prefix to each directory in string
prefix_dir() # <prefix> [dirs...]
{
	local prefix="$1"
	shift
	[[ -z "$@" ]] && return
	printf "$prefix/%s " "$@" | tr -s '/'
}

# Prefix the given directories if they are relative
prefix_dir_if_relative() # <prefix> [dirs...]
{
	local prefix="$1"
	shift
	for j in "$@"; do
		if [[ "${j:0:1}" == '/' ]]; then
			echo -n "$j "
		else
			echo -n "$prefix/$j " | tr -s '/'
		fi
	done
}

# Read flags from a file separated either by spaces or newlines
read_flags() # <flag_file>
{
	[[ ! -e $1 ]] && return
	echo -n ' '
	cat $1 | tr '\n' ' '
}

# Remove all duplicate words in string
remove_duplicates() # [words...]
{
	local -A map
	for i in "$@"; do
		map[$i]=1
	done
	echo "${!map[@]}"
}

# Propagate cxxflags from submodules
write_cxxflags() #
{
	{
		for i in "${submodules[@]}"; do
			read_flags "$i/cxxflags"
		done
	} >> cxxflags
}

# Propagate ldflags from submodules
write_ldflags() #
{
	{
		for i in "${submodules[@]}"; do
			read_flags "$i/ldflags"
		done
	} >> ldflags
}

# Propagate cxxdeps from submodules
write_cxxdeps() #
{
	{
		for i in "${submodules[@]}"; do
			prefix_dir_if_relative "$i/" $(read_flags "$i/cxxdeps")
		done
	} >> cxxdeps
}

# Propagate lddeps from submodules
write_lddeps() #
{
	{
		for i in "${submodules[@]}"; do
			prefix_dir_if_relative "$i/" $(read_flags "$i/lddeps")
		done
	} >> lddeps
}

# Propagate phony targets from submodules
write_targets() #
{
	{
		for i in "${submodules[@]}"; do
			read_flags "$i/targets"
		done
	} >> targets
}

# Generate the Makefile
write_makefile() #
{
	{
		cat <<- EOF
			VPATH := $src
			CXXDEPS :=
			LDDEPS :=
		EOF

		for i in $makefile_vars; do
			echo "$i :="
		done

		for i in "${submodules[@]}"; do
			cat <<- EOF
				CXXFLAGS += $(read_flags "$i/cxxflags")
				LDFLAGS += $(read_flags "$i/ldflags")
				CXXDEPS += $(prefix_dir_if_relative "$i/" $(read_flags "$i/cxxdeps"))
				LDDEPS += $(prefix_dir_if_relative "$i/" $(read_flags "$i/lddeps"))
			EOF
		done

		for i in $makefile_vars; do
			echo "$i += ${!i}"
		done

		cat "$src/Makefile.in"

		cat <<- EOF
			FORCE:
			.PHONY: distclean
			distclean:: clean ; -rm -f $generated_files
			ifneq (,\$(findstring B,\$(MAKEFLAGS)))
				export JWBUILD_MAKECLEAN := yes
			endif
			ifneq (,\$(filter \$(MAKECMDGOALS),clean distclean))
				export JWBUILD_MAKECLEAN := yes
			endif
			ifeq (\$(JWBUILD_MAKECLEAN),)
				Makefile: $src/configure $src/Makefile.in config.status $(realpath ${BASH_SOURCE[0]})
				ifeq (\$(JWBUILD_SUBMAKE),)
					export JWBUILD_SUBMAKE := yes
					Makefile: ; ./config.status
				else
					Makefile: ; touch Makefile
				endif
			endif
		EOF

		for i in "${submodules[@]}"; do
			cat <<- EOF
				.PRECIOUS: $i/%
				$i/%: FORCE ; \$(MAKE) -C $i \$*
				ifeq (\$(JWBUILD_MAKECLEAN),)
					Makefile: $i/Makefile
				endif
			EOF
			for target in $(remove_duplicates $(read_flags "$i/targets")); do
				cat <<- EOF
					.PHONY: $target
					$target: $i/$target
				EOF
			done
			for target in all clean distclean; do
				cat <<- EOF
					.PHONY: $target
					$target:: $i/$target
				EOF
			done
		done
	} >> Makefile
}
