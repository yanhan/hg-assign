import argparse
import json

def gen_csv():
    parser = argparse.ArgumentParser(
        description="Generate metrics csv file from requests, CPU and memory stats JSON",
    )
    parser.add_argument(
        "--requests-file",
        required=True,
        dest="requests_file",
        help="path to JSON file of data points for requests received by nginx ingress controller pod",
    )
    parser.add_argument(
        "--cpu-file",
        required=True,
        dest="cpu_file",
        help="path to JSON file of data points for CPU usage of nginx ingress controller pod",
    )
    parser.add_argument(
        "--memory-file",
        required=True,
        dest="memory_file",
        help="path to JSON file of data points for memory usage of nginx ingress controller pod",
    )
    parser.add_argument(
        "--output",
        required=True,
        dest="output",
        help="destination path for metrics CSV file. This will be overwritten",
    )
    args = parser.parse_args()
    nginx_requests = load_data_values_from_file(args.requests_file)
    cpu_usage = load_data_values_from_file(args.cpu_file)
    memory_usage = load_data_values_from_file(args.memory_file)
    max_starting_timestamp = max(nginx_requests[0][0], cpu_usage[0][0], memory_usage[0][0])
    drop_values_before_timestamp(nginx_requests, max_starting_timestamp)
    drop_values_before_timestamp(cpu_usage, max_starting_timestamp)
    drop_values_before_timestamp(memory_usage, max_starting_timestamp)
    nr_metrics = len(nginx_requests)
    with open(args.output, "w") as f:
        f.write("timestamp,cpu_seconds,memory_bytes,requests_rate\n")
        for i in range(nr_metrics):
            ts = nginx_requests[i][0]
            f.write("{},{},{},{}\n".format(ts, cpu_usage[i][1], memory_usage[i][1], nginx_requests[i][1]))

def drop_values_before_timestamp(vals, ts):
    while vals:
        if vals[0][0] < ts:
            vals.pop(0)
        else:
            break

def load_data_values_from_file(filename):
    values = None
    with open(filename, "r") as f:
        values = json.loads(f.read())
    return values

if __name__ == "__main__":
    gen_csv()
