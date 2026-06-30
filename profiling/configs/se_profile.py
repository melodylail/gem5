#!/usr/bin/env python3
"""
gem5 SE mode profiling script.
Usage: gem5.opt se_profile.py --binary <elf> --output-dir <dir>
"""

import argparse
import os
from pathlib import Path

import m5
from m5.objects import Root

from gem5.components.boards.simple_board import SimpleBoard
from gem5.components.cachehierarchies.classic.private_l1_shared_l2_cache_hierarchy import (
    PrivateL1SharedL2CacheHierarchy,
)
from gem5.components.memory.single_channel import SingleChannelDDR3_1600
from gem5.components.processors.cpu_types import CPUTypes
from gem5.components.processors.simple_processor import SimpleProcessor
from gem5.isas import ISA
from gem5.simulate.simulator import Simulator


def parse_args():
    parser = argparse.ArgumentParser(
        description="gem5 X86 SE mode profiling runner"
    )
    parser.add_argument(
        "--binary",
        required=True,
        help="Path to the statically-linked X86 ELF binary",
    )
    parser.add_argument(
        "--output-dir",
        default="output",
        help="Directory for gem5 stats output",
    )
    parser.add_argument(
        "--arguments",
        nargs="*",
        default=[],
        help="Arguments to pass to the workload binary",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    # Verify binary exists
    binary_path = Path(args.binary).resolve()
    if not binary_path.exists():
        raise FileNotFoundError(f"Binary not found: {binary_path}")

    # Cache hierarchy
    cache_hierarchy = PrivateL1SharedL2CacheHierarchy(
        l1d_size="32kB",
        l1i_size="32kB",
        l2_size="256kB",
    )

    # Memory
    memory = SingleChannelDDR3_1600("1GiB")

    # Processor
    processor = SimpleProcessor(
        cpu_type=CPUTypes.TIMING,
        num_cores=1,
        isa=ISA.X86,
    )

    # Board
    board = SimpleBoard(
        clk_freq="3GHz",
        processor=processor,
        memory=memory,
        cache_hierarchy=cache_hierarchy,
    )

    # Set SE workload
    board.set_se_binary_workload(
        binary=str(binary_path),
        arguments=args.arguments,
    )

    # Simulator
    simulator = Simulator(board=board)

    # Run
    print(f"Starting gem5 SE simulation...")
    print(f"  binary:   {binary_path}")
    print(f"  CPU:      TIMING, 1 core @ 3GHz")
    print(f"  cache:    L1I 32KB, L1D 32KB, L2 256KB")
    print(f"  memory:   DDR3-1600, 1GiB")
    simulator.run()

    print(f"Simulation complete.")


if __name__ == "__m5_main__":
    main()
