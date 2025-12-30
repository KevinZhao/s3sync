#!/usr/bin/env python3
"""
Multi-threaded S3 upload using AWS CRT (Common Runtime)
High-performance upload with automatic multipart and parallel transfers
"""

import os
import sys
import time
import argparse
from pathlib import Path

try:
    import awscrt
    from awscrt.s3 import S3Client, S3RequestType
    from awscrt.auth import AwsCredentialsProvider
    from awscrt.io import ClientBootstrap, DefaultHostResolver, EventLoopGroup
    from awscrt.http import HttpRequest
    import boto3
except ImportError:
    print("Error: Required packages not installed")
    print("Please install: pip install awscrt boto3")
    sys.exit(1)


class UploadProgress:
    """Track upload progress across all files"""

    def __init__(self):
        self.files_completed = 0
        self.files_failed = 0
        self.total_bytes = 0
        self.uploaded_bytes = 0
        self.start_time = time.time()
        self.file_start_times = {}

    def start_file(self, filepath, size):
        self.file_start_times[filepath] = time.time()
        self.total_bytes += size

    def file_completed(self, filepath, size):
        self.files_completed += 1
        self.uploaded_bytes += size
        duration = time.time() - self.file_start_times[filepath]
        speed_mbps = (size / duration / 1024 / 1024) if duration > 0 else 0

        print(f"✅ {filepath}")
        print(f"   Size: {size / (1024**3):.2f} GB, Time: {duration:.1f}s, Speed: {speed_mbps:.1f} MB/s")

        # Overall progress
        elapsed = time.time() - self.start_time
        overall_speed = (self.uploaded_bytes / elapsed / 1024 / 1024) if elapsed > 0 else 0
        progress_pct = (self.uploaded_bytes / self.total_bytes * 100) if self.total_bytes > 0 else 0

        print(f"   Progress: {self.files_completed} files, {progress_pct:.1f}%, {overall_speed:.1f} MB/s average")
        print()

    def file_failed(self, filepath, error):
        self.files_failed += 1
        print(f"❌ {filepath}: {error}")
        print()


def upload_file_crt(s3_client, bucket, local_path, s3_key, progress):
    """
    Upload a single file using AWS CRT S3 client
    Automatically handles multipart upload and parallel transfers
    """
    try:
        file_size = os.path.getsize(local_path)
        progress.start_file(local_path, file_size)

        # Create S3 request
        request = s3_client.make_request(
            request_type=S3RequestType.PUT_OBJECT,
            request={
                'bucket': bucket,
                'key': s3_key,
            },
            filepath=local_path,
        )

        # Wait for completion
        finished_future = request.finished_future
        finished_future.result()

        progress.file_completed(local_path, file_size)
        return True

    except Exception as e:
        progress.file_failed(local_path, str(e))
        return False


def find_files(directory, pattern="*"):
    """Recursively find all files matching pattern"""
    path = Path(directory)
    if path.is_file():
        return [str(path)]

    files = []
    for item in path.rglob(pattern):
        if item.is_file():
            files.append(str(item))

    return sorted(files)


def main():
    parser = argparse.ArgumentParser(
        description='High-performance S3 upload using AWS CRT',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Upload a single file
  %(prog)s /data/models/file.bin my-bucket models/file.bin

  # Upload entire directory
  %(prog)s /data/models my-bucket models/ --recursive

  # Upload with custom settings
  %(prog)s /data/models my-bucket models/ --recursive \\
    --part-size 64 --throughput 10000 --max-connections 100

Performance tips:
  - Larger part-size (32-64 MB) for large files (>10 GB)
  - Higher throughput target for high-bandwidth networks
  - More connections for many small files
        """
    )

    parser.add_argument('source', help='Local file or directory to upload')
    parser.add_argument('bucket', help='S3 bucket name')
    parser.add_argument('destination', help='S3 key prefix (e.g., models/)')

    parser.add_argument('-r', '--recursive', action='store_true',
                        help='Recursively upload directory')
    parser.add_argument('--pattern', default='*',
                        help='File pattern for recursive upload (default: *)')
    parser.add_argument('--part-size', type=int, default=32,
                        help='Multipart upload part size in MB (default: 32)')
    parser.add_argument('--throughput', type=int, default=5000,
                        help='Target throughput in Gbps (default: 5000 = 5 Tbps)')
    parser.add_argument('--max-connections', type=int, default=64,
                        help='Maximum parallel connections (default: 64)')
    parser.add_argument('--region', default=None,
                        help='AWS region (default: from AWS config)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be uploaded without uploading')

    args = parser.parse_args()

    # Validate source
    if not os.path.exists(args.source):
        print(f"Error: Source path does not exist: {args.source}")
        sys.exit(1)

    # Get region
    region = args.region or boto3.Session().region_name or 'us-east-1'

    # Find files to upload
    if args.recursive or os.path.isdir(args.source):
        if not args.recursive and os.path.isdir(args.source):
            print("Error: Source is a directory but --recursive not specified")
            sys.exit(1)

        files = find_files(args.source, args.pattern)
        base_path = Path(args.source)

        # Build upload list with S3 keys
        upload_list = []
        for filepath in files:
            rel_path = Path(filepath).relative_to(base_path)
            s3_key = os.path.join(args.destination, str(rel_path)).replace('\\', '/')
            upload_list.append((filepath, s3_key))
    else:
        # Single file
        s3_key = args.destination
        upload_list = [(args.source, s3_key)]

    if not upload_list:
        print("No files found to upload")
        sys.exit(0)

    # Calculate total size
    total_size = sum(os.path.getsize(f[0]) for f in upload_list)
    total_size_gb = total_size / (1024**3)

    print("=" * 70)
    print("AWS CRT S3 Upload")
    print("=" * 70)
    print(f"Source:        {args.source}")
    print(f"Bucket:        s3://{args.bucket}")
    print(f"Destination:   {args.destination}")
    print(f"Region:        {region}")
    print(f"Files:         {len(upload_list)}")
    print(f"Total size:    {total_size_gb:.2f} GB ({total_size:,} bytes)")
    print()
    print("CRT Settings:")
    print(f"  Part size:        {args.part_size} MB")
    print(f"  Target throughput: {args.throughput} Gbps")
    print(f"  Max connections:  {args.max_connections}")
    print("=" * 70)
    print()

    if args.dry_run:
        print("Dry run - files that would be uploaded:")
        for local_path, s3_key in upload_list:
            size_mb = os.path.getsize(local_path) / (1024**2)
            print(f"  {local_path} -> s3://{args.bucket}/{s3_key} ({size_mb:.1f} MB)")
        print()
        print(f"Total: {len(upload_list)} files, {total_size_gb:.2f} GB")
        return

    # Initialize AWS CRT
    print("Initializing AWS CRT S3 client...")
    event_loop_group = EventLoopGroup(num_threads=2)
    host_resolver = DefaultHostResolver(event_loop_group)
    bootstrap = ClientBootstrap(event_loop_group, host_resolver)

    # Get credentials
    credentials_provider = AwsCredentialsProvider.new_default_chain(bootstrap)

    # Create S3 client with optimized settings
    s3_client = S3Client(
        bootstrap=bootstrap,
        region=region,
        credential_provider=credentials_provider,
        part_size=args.part_size * 1024 * 1024,  # Convert MB to bytes
        throughput_target_gbps=args.throughput,
        tls_mode='enabled',
    )

    print(f"Starting upload of {len(upload_list)} files...")
    print()

    # Track progress
    progress = UploadProgress()
    progress.total_bytes = total_size
    progress.start_time = time.time()

    # Upload all files
    success_count = 0
    for local_path, s3_key in upload_list:
        if upload_file_crt(s3_client, args.bucket, local_path, s3_key, progress):
            success_count += 1

    # Summary
    elapsed = time.time() - progress.start_time
    avg_speed = (progress.uploaded_bytes / elapsed / 1024 / 1024) if elapsed > 0 else 0

    print("=" * 70)
    print("Upload Complete")
    print("=" * 70)
    print(f"Successful:    {success_count}/{len(upload_list)} files")
    print(f"Failed:        {progress.files_failed} files")
    print(f"Total uploaded: {progress.uploaded_bytes / (1024**3):.2f} GB")
    print(f"Total time:    {elapsed:.1f} seconds")
    print(f"Average speed: {avg_speed:.1f} MB/s ({avg_speed * 8 / 1024:.2f} Gbps)")
    print("=" * 70)

    if progress.files_failed > 0:
        sys.exit(1)


if __name__ == '__main__':
    main()
