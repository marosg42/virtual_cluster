#!/usr/bin/env python3
#
# Most of this was generated by Claude from my simpler code
# added overprovisioning and killing with LLM's help
#

import argparse
import concurrent.futures
import fnmatch
import jinja2
import json
import logging
import os
import random
import re
import subprocess
import sys
import threading
import time
import yaml

from pathlib import Path
from queue import Queue, Empty
from urllib.request import urlopen, URLError

LOGGER = logging.getLogger("testflinger-submitter")

# Configuration Constants
AGENT_DATA_URL = "CHANGEME"
OUTPUT_DIR = "output"
DEFAULT_AGENT_LIMIT = 15
DEFAULT_COMPLETION_THRESHOLD = 11
TIMEOUT_SECONDS = 3600  # 1 hour timeout for operations


def get_log_formatter():
    return logging.Formatter(
        fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%d-%H:%M:%S",
    )


def configure_logging(project_dir="generated/sunbeam", log_level=logging.DEBUG):
    """Configure logging.

    :param str project_dir: Project directory
    :param int log_level: logging level. Defaults to logging.INFO
    :returns: None
    """
    default_logger = logging.getLogger()
    default_logger.setLevel(log_level)
    ch = logging.StreamHandler()
    formatter = get_log_formatter()
    ch.setFormatter(formatter)
    ch.setLevel(log_level)
    default_logger.addHandler(ch)
    if os.path.isdir(project_dir):
        fh = logging.FileHandler(os.path.join(project_dir, "output.log"))
        fh.setFormatter(formatter)
        fh.setLevel(log_level)
        default_logger.addHandler(fh)


class TestflingerError(Exception):
    """Base exception for testflinger-related errors."""

    pass


class JobAlreadyCancelledError(TestflingerError):
    """Exception raised when attempting to cancel an already cancelled job."""

    pass


class CancellableThread:
    """A thread that can be signalled to cancel its operation."""

    def __init__(self):
        """Initialize a new cancellable thread with a cancellation event."""
        self.should_cancel = threading.Event()

    def cancel(self):
        """Signal the thread to cancel."""
        self.should_cancel.set()

    def is_cancelled(self):
        """Check if the thread has been signalled to cancel."""
        return self.should_cancel.is_set()


class TestflingerSubmitter:
    """Main class to handle testflinger job submission and monitoring."""

    def __init__(
        self,
        server_file,
        agent_limit=DEFAULT_AGENT_LIMIT,
        completion_threshold=DEFAULT_COMPLETION_THRESHOLD,
    ):
        """
        Initialize the TestflingerSubmitter.

        Args:
            server_file (str): Path to file containing server names
            agent_limit (int): Maximum number of agents to use
            completion_threshold (int): Minimum number of successful completions required
        """
        self.server_file = server_file
        self.agent_limit = agent_limit
        self.completion_threshold = completion_threshold
        self.job_ids = []
        self.result_queue = Queue()

        # Add this new set to track cancelled jobs
        self.cancelled_jobs = set()

        # Job state lock to prevent race conditions when updating job states
        self.job_state_lock = threading.Lock()

        # Ensure output directory exists
        Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)

    def call_testflinger(self, command):
        """
        Call the testflinger CLI with the given command.

        Args:
            command (list): Command arguments for testflinger-cli

        Returns:
            str: Output from the command

        Raises:
            TestflingerError: If the command fails
            JobAlreadyCancelledError: If attempting to cancel an already cancelled job
        """
        cmd = ["testflinger-cli"]
        cmd.extend(command)
        LOGGER.debug("Executing: %s", " ".join(cmd))

        try:
            return subprocess.check_output(
                cmd, stderr=subprocess.STDOUT, timeout=TIMEOUT_SECONDS
            ).decode()
        except subprocess.CalledProcessError as e:
            output = e.output.decode() if e.output else str(e)
            LOGGER.error("Testflinger command failed: %s", output)

            # Check if this is a cancel command on an already cancelled job
            if (
                command[0] == "cancel"
                and "Invalid job ID specified or the job is already completed/cancelled"
                in output
            ):
                raise JobAlreadyCancelledError(
                    f"Job {command[1]} is already cancelled or completed"
                )

            raise TestflingerError(f"Command failed: {' '.join(cmd)}") from e
        except subprocess.TimeoutExpired:
            LOGGER.error(
                "Testflinger command timed out after %s seconds", TIMEOUT_SECONDS
            )
            raise TestflingerError(f"Command timed out: {' '.join(cmd)}")

    def is_job_running(self, job_id):
        """
        Check if a job is currently running and can be cancelled.

        Args:
            job_id (str): The ID of the job to check

        Returns:
            bool: True if the job is still running, False otherwise
        """
        try:
            output = self.call_testflinger(["status", job_id])
            # If "completed" or "cancelled" appears in the status, the job is no longer running
            if "completed" in output or "cancelled" in output:
                return False
            return True
        except TestflingerError:
            # If we can't get the status, assume it's not running
            return False

    def safe_cancel_job(self, job_id):
        """
        Cancel a job safely, checking if it's already been cancelled first.

        Args:
            job_id (str): The ID of the job to cancel

        Returns:
            bool: True if the job was cancelled, False if it was already cancelled
        """
        with self.job_state_lock:
            # Check if this job has already been cancelled
            if job_id in self.cancelled_jobs:
                LOGGER.debug("Job %s already cancelled, skipping", job_id)
                return False

            # Check if the job is still running
            if not self.is_job_running(job_id):
                LOGGER.debug("Job %s no longer running, marking as cancelled", job_id)
                self.cancelled_jobs.add(job_id)
                return False

            try:
                # Try to cancel the job
                self.call_testflinger(["cancel", job_id])
                LOGGER.info("Successfully cancelled job %s", job_id)
                self.cancelled_jobs.add(job_id)
                return True
            except JobAlreadyCancelledError:
                # Job was already cancelled
                LOGGER.debug("Job %s was already cancelled", job_id)
                self.cancelled_jobs.add(job_id)
                return False
            except TestflingerError as e:
                LOGGER.warning("Error cancelling job %s: %s", job_id, str(e))
                return False

    def get_agent_data(self):
        """
        Retrieve agent data from the Testflinger API.

        Returns:
            list: Agent data from the API

        Raises:
            TestflingerError: If API request fails
        """
        try:
            with urlopen(AGENT_DATA_URL, timeout=30) as response:
                if response.getcode() != 200:
                    LOGGER.error(
                        "Failed to retrieve agent data, status code: %s",
                        response.getcode(),
                    )
                    raise TestflingerError(
                        f"API returned status code {response.getcode()}"
                    )
                return json.loads(response.read().decode())
        except (URLError, json.JSONDecodeError) as e:
            LOGGER.error("Error retrieving agent data: %s", str(e))
            raise TestflingerError("Failed to retrieve or parse agent data") from e

    def get_available_agents(self, servers):
        """
        Get a list of available agents that match the given servers.

        Args:
            servers (list): List of server names to match against

        Returns:
            list: Names of available agents sorted by suitability
        """
        try:
            data = self.get_agent_data()
        except TestflingerError as e:
            LOGGER.error("Failed to get agent data: %s", str(e))
            return []

        LOGGER.info("Available agents:")
        LOGGER.info("%-20s %-10s %s", "Name", "State", "Streak")
        LOGGER.info("-" * 40)

        agents = []
        for entry in data:
            # Check if this agent is in any of our target servers
            if not any(server in entry.get("queues", []) for server in servers):
                continue

            name = entry["name"]
            state = entry["state"]

            # Get the streak information
            try:
                streak = entry["provision_streak_count"]
                streak_type = entry.get("provision_streak_type")
                if streak_type == "fail":
                    streak = -streak
            except KeyError:
                streak = 0

            LOGGER.info("%-20s %-10s %s", name, state, streak)

            if state == "waiting":
                agents.append({"name": name, "streak": streak})

        # Sort and shuffle to optimize agent selection
        agents_sorted_by_streak = sorted(
            agents, key=lambda x: x["streak"], reverse=True
        )
        agents_with_positive_streaks = [
            agent for agent in agents_sorted_by_streak if agent["streak"] > 0
        ]
        agents_with_negative_streaks = [
            agent for agent in agents_sorted_by_streak if agent["streak"] <= 0
        ]

        random.shuffle(agents_with_positive_streaks)
        sorted_agents = agents_with_positive_streaks + agents_with_negative_streaks

        LOGGER.info("Sorted agents by preference:")
        LOGGER.info("%-20s %s", "Name", "Streak")
        LOGGER.info("-" * 40)
        for agent in sorted_agents:
            LOGGER.info("%-20s %s", agent["name"], agent["streak"])

        return [agent["name"] for agent in sorted_agents]

    def delete_yaml_files(self):
        """
        Delete any existing testflinger YAML files from the output directory.
        """
        pattern = "testflinger-*.yaml"
        files = [
            f
            for f in os.listdir(OUTPUT_DIR)
            if os.path.isfile(os.path.join(OUTPUT_DIR, f))
        ]
        matching_files = [
            os.path.join(OUTPUT_DIR, f) for f in files if fnmatch.fnmatch(f, pattern)
        ]

        for file in matching_files:
            try:
                os.remove(file)
                LOGGER.debug("Deleted: %s", file)
            except OSError as e:
                LOGGER.warning("Error deleting %s: %s", file, str(e))

    def get_yaml_files(self):
        """
        Get a list of testflinger YAML files in the output directory.

        Returns:
            list: Paths to YAML files
        """
        pattern = "testflinger-*.yaml"
        files = [
            f
            for f in os.listdir(OUTPUT_DIR)
            if os.path.isfile(os.path.join(OUTPUT_DIR, f))
        ]
        return [
            os.path.join(OUTPUT_DIR, f) for f in files if fnmatch.fnmatch(f, pattern)
        ]

    def generate_yaml_files(self, agents):
        """
        Generate YAML files for the given agents using the template.

        Args:
            agents (list): List of agent names
        """
        for agent in agents:
            template_vars = {
                "job_name": f"job-{agent}",
                "job_queue": agent,
                "distro_series": "noble",
            }

            try:
                env = jinja2.Environment(loader=jinja2.FileSystemLoader("."))
                template = env.get_template("testflinger_template_noble.yaml")

                testflinger_filename = os.path.join(
                    OUTPUT_DIR, f"testflinger-{agent}.yaml"
                )
                with open(testflinger_filename, "w") as out:
                    out.write(template.render(**template_vars))
                LOGGER.debug("Generated %s", testflinger_filename)
            except (jinja2.exceptions.TemplateError, OSError) as e:
                LOGGER.error("Error generating YAML for %s: %s", agent, str(e))

    def monitor_subjob(
        self, subjob, result_queue, output_directory, cancellation_token
    ):
        """
        Monitor a single subjob and write its output to a file.
        """
        LOGGER.debug("Capturing %s output started", subjob)
        output_file = os.path.join(output_directory, f"testflinger-{subjob}.txt")

        ret_val = {"ip": "", "job_id": subjob, "name": ""}
        process = None

        try:
            with open(output_file, "w") as file:
                process = subprocess.Popen(
                    ["testflinger-cli", "poll", subjob],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    universal_newlines=True,
                )

                # Set up a separate thread to check for cancellation
                def check_cancellation():
                    while process.poll() is None:
                        if cancellation_token.is_cancelled():
                            LOGGER.info(
                                "Subjob %s received cancellation signal, killing process...",
                                subjob,
                            )
                            # Kill the process immediately
                            try:
                                process.kill()
                            except OSError:
                                pass
                            # Then cancel the job - use the safe_cancel method here
                            self.safe_cancel_job(subjob)
                            return
                        time.sleep(0.5)

                # Start the cancellation checker in a separate thread
                cancellation_checker = threading.Thread(target=check_cancellation)
                cancellation_checker.daemon = True
                cancellation_checker.start()

                # Main loop to read process output
                while process.poll() is None:
                    try:
                        output = process.stdout.readline().strip()
                        if not output:
                            continue

                        if "Starting testflinger provision phase on" in output:
                            LOGGER.debug("%s %s", subjob, output)
                            try:
                                ret_val["name"] = output.split(" ")[-2]
                            except IndexError:
                                LOGGER.warning(
                                    "Could not parse agent name from output: %s", output
                                )

                        file.write(output + os.linesep)
                        file.flush()

                        if "You can now connect to ubuntu@" in output:
                            try:
                                ret_val["ip"] = output.split("@")[-1]
                                LOGGER.info("Job %s has IP %s", subjob, ret_val["ip"])
                                break
                            except IndexError:
                                LOGGER.warning(
                                    "Could not parse IP from output: %s", output
                                )
                    except (ValueError, IOError) as e:
                        LOGGER.error(
                            "Error processing output for %s: %s", subjob, str(e)
                        )
                        break
        except OSError as e:
            LOGGER.error("Error opening output file for %s: %s", subjob, str(e))
        finally:
            if process and process.poll() is None:
                try:
                    process.kill()  # Use kill instead of terminate for immediate effect
                except OSError:
                    pass

            # No need to cancel job here again - it's already handled in check_cancellation
            # Only cancel if the cancellation wasn't handled by check_cancellation
            if cancellation_token.is_cancelled() and subjob not in self.cancelled_jobs:
                self.safe_cancel_job(subjob)

        LOGGER.debug("Capturing %s output finished", subjob)
        LOGGER.debug("Results are %s", ret_val)
        result_queue.put(ret_val)
        return ret_val

    def monitor_subjobs(
        self, subjobs, result_queue, output_directory, completion_threshold
    ):
        """
        Monitor multiple subjobs concurrently.

        Args:
            subjobs (list): List of job IDs to monitor
            result_queue (Queue): Queue to collect results
            output_directory (str): Directory to write output files to
            completion_threshold (int): Number of successful completions required

        Returns:
            int: Number of successfully completed jobs
        """
        LOGGER.info(
            "Monitoring %d subjobs, need %d successful completions",
            len(subjobs),
            completion_threshold,
        )

        cancellation_tokens = {subjob: CancellableThread() for subjob in subjobs}
        future_to_subjob = {}

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=len(subjobs)
        ) as executor:
            # Submit all monitoring tasks
            for subjob in subjobs:
                future = executor.submit(
                    self.monitor_subjob,
                    subjob,
                    result_queue,
                    output_directory,
                    cancellation_tokens[subjob],
                )
                future_to_subjob[future] = subjob

            completed_count = 0
            completed_futures = []

            # Process as they complete
            for future in concurrent.futures.as_completed(
                list(future_to_subjob.keys())
            ):
                subjob = future_to_subjob[future]

                try:
                    result = future.result()
                    completed_futures.append(future)

                    if result["ip"]:
                        LOGGER.info(
                            "Job %s completed successfully with IP: %s",
                            subjob,
                            result["ip"],
                        )
                        completed_count += 1
                    else:
                        LOGGER.warning("Job %s did not produce an IP address", subjob)

                    # Check if we've reached our threshold
                    if completed_count >= completion_threshold:
                        LOGGER.info(
                            "Reached target of %d successful completions!",
                            completion_threshold,
                        )
                        # Cancel all remaining jobs
                        for remaining_subjob, token in cancellation_tokens.items():
                            if remaining_subjob != subjob and not token.is_cancelled():
                                LOGGER.info(
                                    "Sending cancellation signal to subjob %s",
                                    remaining_subjob,
                                )
                                token.cancel()
                        break
                except Exception as e:
                    LOGGER.error("Error monitoring subjob %s: %s", subjob, str(e))

            # Wait a short time for cancellations to take effect before shutting down
            time.sleep(2)

        return completed_count

    def read_servers_file(self):
        """
        Read the servers file and return list of servers.

        Returns:
            list: List of server names

        Raises:
            TestflingerError: If file cannot be read
        """
        try:
            with open(self.server_file, "r") as f:
                return f.read().split()
        except OSError as e:
            LOGGER.error("Error reading servers file: %s", str(e))
            raise TestflingerError(
                f"Could not read servers file: {self.server_file}"
            ) from e

    def create_cancel_script(self):
        """Create a shell script to cancel all jobs if needed."""
        try:
            with open("cancel.sh", "w") as f:
                f.write("#!/bin/bash\n\n")
                f.write("# Auto-generated script to cancel testflinger jobs\n\n")
                for job_id in self.job_ids:
                    f.write(f"testflinger-cli cancel {job_id}\n")
            os.chmod("cancel.sh", 0o755)
            LOGGER.info("Created cancel.sh script")
        except OSError as e:
            LOGGER.warning("Could not create cancel script: %s", str(e))

    def submit_jobs(self):
        """
        Submit generated YAML files as testflinger jobs.

        Returns:
            list: List of job IDs
        """
        job_ids = []
        for file in self.get_yaml_files():
            LOGGER.debug("Submitting job for %s", file)
            try:
                output = self.call_testflinger(["submit", file])
                job_id = re.sub(".*\n.*job_id: ", "", output).strip()
                LOGGER.info("Submitted job %s", job_id)
                job_ids.append(job_id)
            except (TestflingerError, re.error) as e:
                LOGGER.error("Failed to submit job for %s: %s", file, str(e))

        self.job_ids = job_ids
        return job_ids

    def verify_results(self, results):
        """
        Verify the results and cancel any failed jobs.

        Args:
            results (list): List of result dictionaries

        Returns:
            list: List of valid results
        """
        valid_results = []
        for result in results:
            try:
                if not result["job_id"]:
                    continue

                output = self.call_testflinger(["status", result["job_id"]])
                if "reserve" not in output:
                    LOGGER.debug(
                        "%s with %s failed ",
                        result.get("name", "Unknown"),
                        result["job_id"],
                    )
                    # Use safe_cancel instead of direct call
                    self.safe_cancel_job(result["job_id"])
                else:
                    valid_results.append(result)
            except TestflingerError as e:
                LOGGER.warning("Error verifying job %s: %s", result["job_id"], str(e))

        return valid_results

    def run(self):
        """
        Execute the complete testflinger submission and monitoring process.

        Returns:
            int: 0 for success, 1 for failure
        """
        try:
            # Read server list and get available agents
            servers = self.read_servers_file()
            LOGGER.info("Looking for agents on servers: %s", ", ".join(servers))

            agents = self.get_available_agents(servers)[: self.agent_limit]
            if len(agents) < self.agent_limit:
                LOGGER.error(
                    "Not enough available agents: %d (need %d)",
                    len(agents),
                    self.agent_limit,
                )
                return 1

            # Delete old files and generate new ones
            self.delete_yaml_files()
            self.generate_yaml_files(agents)

            # Submit jobs
            self.job_ids = self.submit_jobs()
            if not self.job_ids:
                LOGGER.error("No jobs were submitted successfully")
                return 1

            self.create_cancel_script()

            # Monitor jobs
            completion_count = self.monitor_subjobs(
                self.job_ids, self.result_queue, OUTPUT_DIR, self.completion_threshold
            )

            if completion_count < self.completion_threshold:
                LOGGER.error(
                    "Not enough completions (%d/%d), cancelling all jobs",
                    completion_count,
                    self.completion_threshold,
                )
                for job_id in self.job_ids:
                    if job_id not in self.cancelled_jobs:
                        self.safe_cancel_job(job_id)
                return 1

            # Collect and verify results
            results = []
            try:
                while not self.result_queue.empty():
                    results.append(self.result_queue.get(block=False))
            except Empty:
                pass

            valid_results = self.verify_results(results)

            # Output results
            print(yaml.dump(valid_results, sort_keys=False))
            ip_addresses = [result["ip"] for result in valid_results if result["ip"]]
            print(" ".join(ip_addresses))
            return 0

        except TestflingerError as e:
            LOGGER.error("Fatal error: %s", str(e))
            return 1
        except Exception as e:
            LOGGER.exception("Unexpected error: %s", str(e))
            return 1


def parse_arguments():
    """
    Parse command line arguments.

    Returns:
        argparse.Namespace: Parsed arguments
    """
    parser = argparse.ArgumentParser(description="Submit and monitor testflinger jobs")
    parser.add_argument("server_file", help="File containing server names")
    parser.add_argument(
        "--agent-limit",
        type=int,
        default=DEFAULT_AGENT_LIMIT,
        help=f"Maximum number of agents to use (default: {DEFAULT_AGENT_LIMIT})",
    )
    parser.add_argument(
        "--completion-threshold",
        type=int,
        default=DEFAULT_COMPLETION_THRESHOLD,
        help=f"Minimum successful completions required (default: {DEFAULT_COMPLETION_THRESHOLD})",
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")

    return parser.parse_args()


if __name__ == "__main__":
    args = parse_arguments()
    configure_logging()

    submitter = TestflingerSubmitter(
        args.server_file,
        agent_limit=args.agent_limit,
        completion_threshold=args.completion_threshold,
    )

    exit_code = submitter.run()
    sys.exit(exit_code)
