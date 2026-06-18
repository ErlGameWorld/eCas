%%%-------------------------------------------------------------------
%%% @doc pg_cache_schema 定义汇总
%%% 此文件由 genPSchema 自动生成，请勿手动修改。
%%%-------------------------------------------------------------------
-ifndef(PG_CACHE_SCHEMA_HRL).
-define(PG_CACHE_SCHEMA_HRL, true).

%%PostgreSQL 玩家主表，全量缓存 + 定时整行落盘
-type players() :: #{
    id => integer()                                                         %% 玩家 ID
    , account => binary()                                                   %% 账号
    , level => integer()                                                    %% 等级
    , gold => integer()                                                     %% 金币
    , profile => map()                                                      %% 扩展资料
    , created_at => binary()                                                %% 创建时间
}.

-define(players_map(), #{
    id => undefined                                                         %% 玩家 ID
    , account => undefined                                                  %% 账号
    , level => 1                                                            %% 等级
    , gold => 0                                                             %% 金币
    , profile => #{}                                                        %% 扩展资料
    , created_at => undefined                                               %% 创建时间
}).

%%PostgreSQL 道具表，热数据缓存 + dirty
-type items() :: #{
    id => integer()                                                         %% 道具 ID
    , player_id => integer()                                                %% 玩家 ID
    , item_type => atom()                                                   %% 道具类型
    , count => integer()                                                    %% 数量
    , attrs => map()                                                        %% 属性
    , updated_at => binary()                                                %% 更新时间
}.

-define(items_map(), #{
    id => undefined                                                         %% 道具 ID
    , player_id => undefined                                                %% 玩家 ID
    , item_type => undefined                                                %% 道具类型
    , count => 1                                                            %% 数量
    , attrs => #{}                                                          %% 属性
    , updated_at => undefined                                               %% 更新时间
}).

%%PostgreSQL 会话快照，热数据缓存 + 自定义 loadFun
-record(session_snapshots, {
    id :: integer()                                                         %% 快照 ID
    , player_id :: integer()                                                %% 玩家 ID
    , dirty_flag = 0 :: integer()                                           %% 脏标记
    , online = false :: boolean()                                           %% 在线状态
    , payload :: term()                                                     %% 快照内容
    , heartbeat_at :: binary()                                              %% 心跳时间
}).

%%PostgreSQL 系统配置，只读缓存
-type sys_config() :: #{
    key => binary()                                                         %% 配置键
    , value => term()                                                       %% 配置值
    , remark => binary()                                                    %% 备注
}.

-define(sys_config_map(), #{
    key => undefined                                                        %% 配置键
    , value => #{}                                                          %% 配置值
    , remark => <<>>                                                        %% 备注
}).

%%PostgreSQL 类型覆盖样例
-type type_showcase() :: #{
    id => binary()                                                          %% 主键
    , score => number()                                                     %% 积分
    , title => binary()                                                     %% 标题
    , region => binary()                                                    %% 区服代码
    , status => binary()                                                    %% 状态
    , labels => [binary()]                                                  %% 标签数组
    , login_ip => binary()                                                  %% 登录 IP
    , payload_text => term()                                                %% 可读结构体
    , event_date => binary()                                                %% 事件日期
    , event_time => binary()                                                %% 事件时间
}.

-define(type_showcase_map(), #{
    id => undefined                                                         %% 主键
    , score => 0                                                            %% 积分
    , title => undefined                                                    %% 标题
    , region => undefined                                                   %% 区服代码
    , status => <<"active">>                                                %% 状态
    , labels => undefined                                                   %% 标签数组
    , login_ip => undefined                                                 %% 登录 IP
    , payload_text => undefined                                             %% 可读结构体
    , event_date => undefined                                               %% 事件日期
    , event_time => undefined                                               %% 事件时间
}).


-endif.
