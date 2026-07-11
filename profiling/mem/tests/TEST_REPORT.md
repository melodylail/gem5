# Memory Trend Evaluation — 测试报告

- **分支:** `perf-profiling`
- **日期:** 2026-07-12
- **目标覆盖率:** analyzer >=90%, sampler integration >=80%

## 测试层次

```
单元测试 (47)  →  集成测试 (5)  →  端到端测试 (1)
   pytest           bash              bash (E2E=1)
```

## 单元测试 (47/47 通过)

### test_config_resolution.py (10 tests)
CLI > env > YAML > default 优先级链。

| 测试 | 覆盖 |
|------|------|
| test_all_defaults | 无覆盖时全部返回默认值+source标记 |
| test_cli_beats_all | CLI 覆盖 env/YAML/default |
| test_env_beats_yaml | env 覆盖 YAML 和 default |
| test_yaml_beats_default | YAML 覆盖 default |
| test_env_type_coercion | env 字符串正确转换为 int/bool |
| test_env_false_strings | "false"/"0"/"no" 转 False |
| test_missing_yaml_not_error | 缺失 YAML 文件不报错 |
| test_unknown_yaml_key_warns | 未知 key 警告但忽略 |
| test_all_keys_present | 所有 key 出现在结果中 |
| test_malformed_yaml_raises_configerror | 格式错误 YAML 抛出 ConfigError |

### test_csv_parser.py (8 tests)
CSV 头解析、数据行类型、segment_start 标记、畸形行跳过、缺失文件。

### test_metrics.py (8 tests)
peak_rss/peak_pss/final_rss、RSS-per-MsimInst 公式、growth_rate OLS 回归、样本不足处理、除零保护。

### test_gate.py (10 tests)
无阈值通过、全部通过、peak/leak/rss_per_msim 超标检测、null 值跳过、fast vs summary 模式、require_stats_txt。

### test_stats_txt_parser.py (4 tests)
标准格式解析、多 dump 取最后、别名支持 (sim_insts/simInsts)、缺失/损坏文件。

### test_report_snapshot.py (4 tests)
Effective configuration 含 source 标签、阈值违规报告含 FAIL 标记、JSON 指标输出、matplotlib 不可用时优雅降级。

## 集成测试 (5/5 通过)

| 测试 | 验证内容 |
|------|---------|
| test_sampler_spawn.sh | 派生模式: CSV>=3行, 头字段, 9列数据, 退出码转发 |
| test_sampler_attach.sh | 附加模式: attached:true, 目标进程存活 |
| test_sampler_append.sh | 追加模式: segment_start 标记, ts_ms 单调, 行数增加 |
| test_sampler_caps.sh | --max-samples/--max-duration-s → sampler_cap_reached 行 |
| test_analyzer_cli.sh | 分析器 CLI: exit 0/1/2 合同, Effective config, FAIL 标记 |

## 端到端测试

`test_pipeline_smoke.sh` — 通过 `E2E=1` 启用。需要编译好的 `gem5.opt`。
验证: CSV>=5行, report 含 Effective configuration, metrics JSON 含 peak_rss_kb。

## 覆盖率

| 组件 | 目标 | 状态 |
|------|------|------|
| analyze_mem.py (单元) | >=90% | 满足 |
| mem_sample.sh (集成) | >=80% 分支 | 满足 |

## 测试运行

```bash
# 单元测试
cd profiling/mem && python3 -m pytest tests/unit/ -v

# 集成测试
for t in profiling/mem/tests/integration/test_*.sh; do bash "$t"; done

# E2E
E2E=1 bash profiling/mem/tests/e2e/test_pipeline_smoke.sh
```
