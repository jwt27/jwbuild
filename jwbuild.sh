#!/usr/bin/false

# Expected variables on entry:
# $src: source directory

set -e

declare -A options
declare -A saved_vars
declare makefile_vars
declare -a submodules
declare -A submodule_args
declare -ra arguments=("$@")
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

# Parse boolean string and return as exit code.  Return default value if empty.
test_bool() # <value> <default_value>
{
	local default=1
	if [[ ! -z "$2" ]]; then
		if test_bool $2; then
			default=0
		else
			default=1
		fi
	fi
	case "$1" in
	true)  return 0 ;;
	false) return 1 ;;
	y*)    return 0 ;;
	Y*)    return 0 ;;
	n*)    return 1 ;;
	N*)    return 1 ;;
	1)     return 0 ;;
	0)     return 1 ;;
	'')    return $default ;;
	*)     fail "unrecognized boolean value $1"
	esac
}

# Parse boolean option and return as exit code.  Return default value if empty.
test_option() # <option_name> <default_value>
{
	if test_bool "${options[$1]}" $2; then
		options[$1]=yes
		return 0
	else
		options[$1]=no
		return 1
	fi
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

# Clean up generated files from a previous configuration
cleanup() #
{
	if test_option help; then
		fail "no help message!"
	fi
	if [[ -e Makefile ]]; then
		make distclean > /dev/null 2>&1 || :
	fi

	rm -f $generated_files
}

# Generate config.status
save_config() #
{
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

# Prepend the given prefix to each word in string
add_prefix() # <prefix> [words...]
{
	local prefix=$1
	shift
	[[ -z "$@" ]] && return
	printf "$prefix/%s " "$@" | tr -s '/'
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
	declare -A map
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
			add_prefix "$i/" $(read_flags "$i/cxxdeps")
		done
	} >> cxxdeps
}

# Propagate lddeps from submodules
write_lddeps() #
{
	{
		for i in "${submodules[@]}"; do
			add_prefix "$i/" $(read_flags "$i/lddeps")
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
			echo "$i := ${!i}"
		done

		for i in "${submodules[@]}"; do
			cat <<- EOF
				CXXFLAGS += $(read_flags "$i/cxxflags")
				LDFLAGS += $(read_flags "$i/ldflags")
				CXXDEPS += $(add_prefix "$i/" $(read_flags "$i/cxxdeps"))
				LDDEPS += $(add_prefix "$i/" $(read_flags "$i/lddeps"))
			EOF
		done

		cat "$src/Makefile.in"

		for i in "${submodules[@]}"; do
			cat <<- EOF
				.PRECIOUS: $i/%
				$i/%: FORCE ; \$(MAKE) -C $i \$*
			EOF
			for target in $(remove_duplicates $(read_flags "$i/targets") all clean distclean); do
				cat <<- EOF
					.PHONY: $target
					$target: $i/$target
				EOF
			done
		done
		local -r makefile_deps="$src/configure $src/Makefile.in config.status $(realpath ${BASH_SOURCE[0]})"
		cat <<- EOF
			FORCE:
			.PHONY: distclean
			distclean: clean ; -rm -f $generated_files
			ifeq (,\$(filter \$(MAKECMDGOALS),clean distclean))
				Makefile: $makefile_deps ; ./config.status
			endif
		EOF
	} >> Makefile
}
