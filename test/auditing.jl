# Tests for our auditing infrastructure

@testset "Auditor - ISA tests" begin
    mktempdir() do build_path
        products = Product[
            ExecutableProduct("main_sse", :main_sse),
            ExecutableProduct("main_avx", :main_avx),
            ExecutableProduct("main_avx2", :main_avx2),
        ]

        build_output_meta = autobuild(
            build_path,
            "isa_tests",
            v"1.0.0",
            [build_tests_dir],
            # Build the test suite, install the binaries into our prefix's `bin`
            raw"""
            cd ${WORKSPACE}/srcdir/isa_tests
            make -j${nproc} install
            install_license /usr/include/ltdl.h
            """,
            # Build for our platform
            [platform],
            # Ensure our executable products are built
            products,
            # No dependencies
            [];
            # We need to build with very recent GCC so that we can emit AVX2
            preferred_gcc_version=v"8",
        )

        # Extract our platform's build
        @test haskey(build_output_meta, platform)
        tarball_path, tarball_hash = build_output_meta[platform][1:2]
        @test isfile(tarball_path)

        # Unpack it somewhere else
        @test verify(tarball_path, tarball_hash)
        testdir = joinpath(build_path, "testdir")
        mkdir(testdir)
        unpack(tarball_path, testdir)
        prefix = Prefix(testdir)

        # Run ISA tests
        for (product, true_isa) in zip(products, (:core2, :sandybridge, :haswell))
            readmeta(locate(product, prefix)) do oh
                detected_isa = BinaryBuilder.analyze_instruction_set(oh, platform; verbose=true)
                @test detected_isa == true_isa
            end
        end
    end
end

@testset "Auditor - .dll moving" begin
    for platform in [Linux(:x86_64), Windows(:x86_64)]
        mktempdir() do build_path
            build_output_meta = autobuild(
                build_path,
                "dll_moving",
                v"1.0.0",
                [],
                # Intsall a .dll into lib
                raw"""
                mkdir -p ${prefix}/lib
                cc -o ${prefix}/lib/libfoo.${dlext} -shared /usr/share/testsuite/c/dyn_link/libfoo/libfoo.c
                install_license /usr/include/ltdl.h
                """,
                # Build for our platform
                [platform],
                # Ensure our executable products are built
                Product[LibraryProduct("libfoo", :libfoo)],
                # No dependencies
                [];
                # We need to build with very recent GCC so that we can emit AVX2
                preferred_gcc_version=v"8",
            )

            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Test that `libfoo.dll` gets moved to `bin` if it's a windows
            contents = list_tarball_files(tarball_path)
            dir = isa(platform, Windows) ? "bin" : "lib"
            @test "$(dir)/libfoo.$(dlext(platform))" in contents
        end
    end
end

@testset "Auditor - .dylib identity mismatch" begin
    mktempdir() do build_path
        no_id = LibraryProduct("no_id", :no_id)
        abs_id = LibraryProduct("abs_id", :wrong_id)
        wrong_id = LibraryProduct("wrong_id", :wrong_id)
        right_id = LibraryProduct("right_id", :wrong_id)
        platform = MacOS()

        build_output_meta = autobuild(
            build_path,
            "dll_moving",
            v"1.0.0",
            [],
            # Intsall a .dll into lib
            raw"""
            mkdir -p ${prefix}/lib
            SRC=/usr/share/testsuite/c/dyn_link/libfoo/libfoo.c
            cc -o ${libdir}/no_id.${dlext} -shared $SRC
            cc -o ${libdir}/abs_id.${dlext} -Wl,-install_name,${libdir}/abs_id.${dlext} -shared $SRC
            cc -o ${libdir}/wrong_id.${dlext} -Wl,-install_name,@rpath/totally_different.${dlext} -shared $SRC
            cc -o ${libdir}/right_id.${dlext} -Wl,-install_name,@rpath/right_id.${dlext} -shared $SRC
            install_license /usr/include/ltdl.h
            """,
            # Build for MacOS
            [platform],
            # Ensure our executable products are built
            Product[no_id, abs_id, wrong_id, right_id],
            # No dependencies
            [],
        )

        # Extract our platform's build
        @test haskey(build_output_meta, platform)
        tarball_path, tarball_hash = build_output_meta[platform][1:2]
        @test isfile(tarball_path)

        # Unpack it somewhere else
        @test verify(tarball_path, tarball_hash)
        testdir = joinpath(build_path, "testdir")
        mkdir(testdir)
        unpack(tarball_path, testdir)
        prefix = Prefix(testdir)

        # Helper to extract the dylib id of a path
        function get_dylib_id(path)
            return readmeta(path) do oh
                dylib_id_lcs = [lc for lc in MachOLoadCmds(oh) if isa(lc, MachOIdDylibCmd)]
                @test !isempty(dylib_id_lcs)
                return dylib_name(first(dylib_id_lcs))
            end
        end

        # Locate the build products within the prefix, ensure that all the dylib ID's
        # now match the pattern `@rpath/$(basename(p))`
        no_id_path = locate(no_id, prefix; platform=platform)
        abs_id_path = locate(abs_id, prefix; platform=platform)
        right_id_path = locate(right_id, prefix; platform=platform)
        for p in (no_id_path, abs_id_path, right_id_path)
            @test any(startswith.(p, libdirs(prefix)))
            @test get_dylib_id(p) == "@rpath/$(basename(p))"
        end

        # Only if it already has an `@rpath/`-ified ID, it doesn't get touched.
        wrong_id_path = locate(wrong_id, prefix; platform=platform)
        @test any(startswith.(wrong_id_path, libdirs(prefix)))
        @test get_dylib_id(wrong_id_path) == "@rpath/totally_different.dylib"
    end
end

@testset "Auditor - absolute paths" begin
    mktempdir() do build_path
        sharedir = joinpath(realpath(build_path), "share")
        mkpath(sharedir)
        open(joinpath(sharedir, "foo.conf"), "w") do f
            write(f, "share_dir = \"$sharedir\"")
        end

        # Test that `audit()` warns about an absolute path within the prefix
        @test_warn "share/foo.conf" BinaryBuilder.audit(Prefix(build_path); verbose=true)
    end
end

@testset "Auditor - gcc version" begin
    # These tests assume our gcc version is concrete (e.g. that Julia is linked against libgfortran)
    our_libgfortran_version = libgfortran_version(compiler_abi(platform))
    @test our_libgfortran_version != nothing

    # Get one that isn't us.
    other_libgfortran_version = v"4"
    if our_libgfortran_version == other_libgfortran_version
        other_libgfortran_version = v"5"
    end

    our_platform = platform
    other_platform = BinaryBuilder.replace_libgfortran_version(our_platform, other_libgfortran_version)
    
    for platform in (our_platform, other_platform)
        # Build `hello_world` in fortran for all three platforms; on our platform we expect it
        # to run, on `other` platform we expect it to not run, on `fail` platform we expect it
        # to throw an error during auditing:
        mktempdir() do build_path
            hello_world = ExecutableProduct("hello_world_fortran", :hello_world_fortran)
            build_output_meta = autobuild(
                build_path,
                "hello_fortran",
                v"1.0.0",
                # No sources
                [],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                # Build fortran hello world
                make -j${nproc} -sC /usr/share/testsuite/fortran/hello_world install
                # Install fake license just to silence the warning
                install_license /usr/share/licenses/libuv/LICENSE
                """,
                # Build for ALL the platforms
                [platform],
                # 
                Product[hello_world],
                # No dependencies
                [];
            )

            # Extract our platform's build, run the hello_world tests:
            output_meta = select_platform(build_output_meta, platform)
            @test output_meta != nothing
            tarball_path, tarball_hash = output_meta[1:2]

            # Ensure the build products were created
            @test isfile(tarball_path)

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)

            # Attempt to run the executable, but only expect it to work if it's our platform:
            hello_world_path = locate(hello_world, Prefix(testdir); platform=platform)
            with_libgfortran() do
                if platform == our_platform
                    @test strip(String(read(`$hello_world_path`))) == "Hello, World!"
                elseif platform == other_platform
                    fail_cmd = pipeline(`$hello_world_path`, stdout=devnull, stderr=devnull)
                    @test_throws ProcessFailedException run(fail_cmd)
                end
            end

            # If we audit the testdir, pretending that we're trying to build an ABI-agnostic
            # tarball, make sure it warns us about it.
            @test_warn "links to libgfortran!" BinaryBuilder.audit(Prefix(testdir); platform=BinaryBuilder.abi_agnostic(platform), autofix=false)
        end
    end
end
