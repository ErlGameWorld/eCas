-module(schema_codegen_eunit).

-include_lib("eunit/include/eunit.hrl").

mysql_generator_test() ->
    run_generator_test(mysql,
        fun() -> genMSchema:gen("./src/schema/mysql", test_mysql_db_schema, test_mysql_cache_def, "./_tmp_test/mysql/src", "./_tmp_test/mysql/include", ["./include"]) end,
        "./_tmp_test/mysql/src/test_mysql_db_schema.erl",
        "./_tmp_test/mysql/src/test_mysql_cache_def.erl").

postgresql_generator_test() ->
    run_generator_test(postgresql,
        fun() -> genPSchema:gen("./src/schema/postgresql", test_pg_db_schema, test_pg_cache_def, "./_tmp_test/postgresql/src", "./_tmp_test/postgresql/include", ["./include"]) end,
        "./_tmp_test/postgresql/src/test_pg_db_schema.erl",
        "./_tmp_test/postgresql/src/test_pg_cache_def.erl").

run_generator_test(_Dialect, Fun, SchemaFile, CacheFile) ->
    cleanup_tmp(),
    try
        ok = Fun(),
        ?assert(filelib:is_file(SchemaFile)),
        ?assert(filelib:is_file(CacheFile)),
        {ok, SchemaBin} = file:read_file(SchemaFile),
        {ok, CacheBin} = file:read_file(CacheFile),
        ?assertNotEqual(nomatch, binary:match(SchemaBin, <<"tableSchema_">>)),
        ?assertNotEqual(nomatch, binary:match(CacheBin, <<"#tbCache{">>))
    after
        cleanup_tmp()
    end.

cleanup_tmp() ->
    _ = file:del_dir_r("./_tmp_test"),
    ok.
