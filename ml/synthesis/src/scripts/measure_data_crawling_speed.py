import asyncio
import sys
from pathlib import Path
from time import perf_counter

from components.common.logging import configure_logging, get_logger
from components.data_crawling.example_running import produce_data_for_example

if __name__ == "__main__":
    logger = get_logger(__name__)
    configure_logging()

    example = Path(r"examples/fibonacci.lua")
    if len(sys.argv) == 2:
        example = Path(sys.argv[1])
    else:
        logger.info(f"default algorithm: {example}")
    start_time = perf_counter()
    asyncio.run(produce_data_for_example(example))
    logger.info(f"Finished in {perf_counter() - start_time:.2f} s")
