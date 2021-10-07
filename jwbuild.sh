#!/usr/bin/false

# Expected variables on entry:
# $src : source directory
# $vars: list of variables to save

set -e

declare -A options
declare -A saved_vars
declare -A libraries
declare -a arguments

arguments=("$@")

# cleanup
cleanup()
{
	# Clean up
	if [[ -e Makefile ]]; then
		make distclean > /dev/null 2>&1 || :
	fi

	rm -f Makefile config.status cxxflags ldflags name 2> /dev/null || :
}

# fail [message]
fail()
{
	echo Error: "$@" 1>&2
	exit 1
}

# warn [message]
warn()
{
	echo Warning: "$@" 1>&2
}

for i in $vars; do
	saved_vars[$i]="${!i}"
	export $i
done

for i in "${arguments[@]}"; do
	case "$i" in
	--*=*)
		i="${i#--}"
		var="${i%%=*}"
		value="${i#*=}"
		options["$var"]="$value"
		;;
	--*)
		i="${i#--}"
		options[$i]=yes
		;;
	*=*)
		var="${i%%=*}"
		value="${i#*=}"
		eval "$var"="'$value'"
		;;
	*)
		fail "invalid argument: $i"
		;;
	esac
done

# save_config
save_config()
{
	# Generate config.status
	{
		echo '#!/usr/bin/env bash'
		for i in "${!saved_vars[@]}"; do
			echo "export $i='${saved_vars[$i]}'"
		done
		for i in "$0" "${arguments[@]}"; do
			echo -n "'$i' "
		done
		echo
	} >> config.status
	chmod +x config.status
}

# abspath <path>
abspath()
{
	echo $(cd $(dirname "$@") && pwd)/$(basename "$@")
}

# winpath <path>
winpath()
{
	case $(uname) in
	MINGW*) echo "$(cygpath -w "$@")" ;;
	*) echo "$@" ;;
	esac
}

# have_program <program_name>
have_program()
{
	which "$@" 2>&1 > /dev/null
}

# check_programs <program_names...>
check_programs()
{
	for i in "$@"; do
		if ! have_program $i; then
			fail "$i not found"
		fi
	done
}

# compile [extra_flags...]
compile()
{
	set +e
	$CXX $CXXFLAGS "$@" -x c++ -c -o tmpfile - > /dev/null
	local status=$?
	rm -f tmpfile 2> /dev/null
	return $status
}

# compile_exe [extra_flags...]
compile_exe()
{
	set +e
	$CXX $CXXFLAGS "$@" -x c++ -o tmpfile $LDFLAGS - > /dev/null
	local status=$?
	rm -f tmpfile 2> /dev/null
	return $status
}

# compile_silent [extra_flags...]
compile_silent()
{
	compile "$@" > /dev/null 2>&1
}

# compile_exe_silent [extra_flags...]
compile_exe_silent()
{
	compile_exe "$@" > /dev/null 2>&1
}

# check_compiler [cxxflags_to_test...]
check_compiler()
{
	echo | compile || fail "compiler does not work"
	for i in "$@"; do
		echo | compile $i || fail "compiler does not understand $i"
	done
}

# add_library <relative_directory> [configure_args...]
add_library()
{
	local dir=$1
	shift
	mkdir -p $dir
	( cd $dir && $src/$dir/configure "$@" )
	libraries["$(cat "$dir/name")"]="$dir"
}

# read_flags <flag_file>
read_flags()
{
	echo -n ' '
	cat $1 | tr '\n' ' '
}

# write_cxxflags
write_cxxflags()
{
	{
		for i in "${libraries[@]}"; do
			if [[ -e "$i/cxxflags" ]]; then
				cat "$i/cxxflags"
			fi
		done
	} >> cxxflags
}

# write_ldflags
write_ldflags()
{
	{
		for i in "${libraries[@]}"; do
			if [[ -e "$i/ldflags" ]]; then
				cat "$i/ldflags"
			fi
		done
	} >> ldflags
}

# write_makefile
write_makefile()
{
	{
		echo "VPATH := $src"

		for i in "${!saved_vars[@]}"; do
			echo "$i := ${!i}"
		done

		if [[ -e cxxflags ]]; then
			echo "CXXFLAGS += $(read_flags cxxflags)"
		fi

		if [[ -e ldflags ]]; then
			echo "LDFLAGS += $(read_flags ldflags)"
		fi

		cat "$src/Makefile.in"

		for i in "${!libraries[@]}"; do
			local dir="${libraries[$i]}"
			echo ".PHONY: $i"
			echo "$i:"
			echo "	\$(MAKE) -C '$dir'"
			echo "clean:"
			echo "	\$(MAKE) -C '$dir' clean"
			echo "$i/Makefile:"
			echo "	\$(MAKE) -C '$dir' Makefile"
			echo "Makefile: $i/Makefile"
		done

		echo "ifneq (\$(MAKECMDGOALS),distclean)"
		echo "Makefile: $src/configure $src/Makefile.in config.status"
		echo "	./config.status"
		echo "endif"
		echo
		echo "distclean: clean"
		echo "	-rm -f Makefile config.status cxxflags ldflags"
	} >> Makefile
}
