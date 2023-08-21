from __future__ import annotations

import logging
from dataclasses import asdict
from pathlib import Path
from typing import Dict

from components.common.logging import get_logger
from components.common.saving import save_dicts_list_to_csv_with_timestamp
from components.data_crawling.tree_sampling.result_processing import SamplingResult, process_and_save_sampling_results
from components.data_crawling.tree_sampling.tree_sampling import run_synthesis_tree_sampling
from consts import DATA_DIR, EXAMPLES_DIR

logger = get_logger(__name__)


async def crawl_data_from_example(example: Path, data_dir: Path = DATA_DIR, **runner_kwargs) -> SamplingResult | None:
    """
    This function shouldn't raise any exceptions, so the burden of handling errors generated by the circus inside
    run_example_and_sample_tree does not leak outside this function. It can be safely called straight from main().
    """
    # TODO: rename "example" to "target algorithm" everywhere?
    logger.info(f"Starting producing model input data from a target algorithm at {example}")

    if not example.exists():
        logger.error(f"Couldn't find a target algorithm description at '{example.absolute()}'.")
        return None

    results: list[dict] = []

    try:
        await run_synthesis_tree_sampling(
            example,
            results_accum=results,
            **runner_kwargs,
        )
    except KeyboardInterrupt:
        logger.info("Interrupted by user, processing nodes gathered so far.")
    except Exception:
        logger.exception("Unexpected error, processing nodes gathered so far.")

    return process_and_save_sampling_results(example, results, data_dir)


CrawlConfig = Dict[Path, dict]  # example_filename -> runner_kwargs
MANUAL_FULL_CRAWL_CONFIG: CrawlConfig = {
    EXAMPLES_DIR / "spi3.lua": dict(n_samples_per_batch=149, n_samples=39757),
    EXAMPLES_DIR / "sum.lua": dict(n_samples_per_batch=131, n_samples=28014),
    EXAMPLES_DIR / "constantFolding.lua": dict(n_samples_per_batch=128, n_samples=26607),
    EXAMPLES_DIR / "pid.lua": dict(n_samples_per_batch=72, n_samples=14356),
    EXAMPLES_DIR / "teacup.lua": dict(n_samples_per_batch=88, n_samples=16559),
    EXAMPLES_DIR / "generated/matrix-mult-1x3.lua": dict(n_samples_per_batch=98, n_samples=18219),
    EXAMPLES_DIR / "generated/cyclic3.lua": dict(n_samples_per_batch=95, n_samples=17677),
    EXAMPLES_DIR / "generated/cyclic4.lua": dict(n_samples_per_batch=63, n_samples=13345),
    EXAMPLES_DIR / "generated/cyclic5.lua": dict(n_samples_per_batch=59, n_samples=12933),
    EXAMPLES_DIR / "generated/vars.lua": dict(n_samples_per_batch=27, n_samples=10452),
}
"""
Those examples are manually chosen to have:
1) ~400k training data rows per example
2) ~50% grand total negative label share

How it was done:
- all examples were evaluated with a fixed test number of samples
- their stats (see csv crawling summary) were examined (negative label share and average result rows yield per sample)
- only examples with 0 < neg_label_share < 1 were taken (presented here) <- COULD BE IMPROVED, lots of examples with =1
- n_samples was chosen based on avg_result_rows_per_sample so that the number of result rows is ~400k per example
- batch sizes are adjusted so the frequency of progress bar updates (once per batch) looks consistent

TODO: automation script for all this optimal crawl config selection procedure?
"""


async def crawl_data_from_many_examples(crawl_config: CrawlConfig | None = None):
    if crawl_config is None:
        logger.info("Using the default hardcoded state of the art crawl config.")
        crawl_config = MANUAL_FULL_CRAWL_CONFIG

    examples_str = "\n\t".join(str(e) for e in crawl_config.keys())
    logger.info(f"Crawling the data from {len(crawl_config)} examples: \n\t{examples_str}")

    summary_stats: list[dict] = []

    for i, (example, kwargs) in enumerate(crawl_config.items()):
        # intentionally using root logger here, otherwise module name is too long and this bar is shifted to the right
        logging.info(f"===================== Processing {example} ({i+1} / {len(crawl_config)}) =====================")
        sampling_result = await crawl_data_from_example(example, **kwargs)
        if sampling_result is not None:
            summary_stats.append({"example": example.name, **asdict(sampling_result.stats)})

    logger.info(f"Done! Produced crawling summary for {len(summary_stats)} examples.")
    save_dicts_list_to_csv_with_timestamp(summary_stats, DATA_DIR, "_crawling_summary", what="crawling summary")
