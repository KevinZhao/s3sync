#!/usr/bin/env python3
import json
import os
import signal
import sys
import time
import urllib.parse
from typing import Optional
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

REGION = os.environ["REGION"]
SRC_BUCKET = os.environ["SRC_BUCKET"]
DST_BUCKET = os.environ["DST_BUCKET"]
QUEUE_URL = os.environ["QUEUE_URL"]
PREFIX_FILTER = os.environ.get("PREFIX_FILTER", "")
VISIBILITY_TIMEOUT = int(os.environ.get("VISIBILITY_TIMEOUT", "7200"))
WAIT_TIME_SECONDS = int(os.environ.get("WAIT_TIME_SECONDS", "20"))
EMPTY_POLLS_BEFORE_EXIT = int(os.environ.get("EMPTY_POLLS_BEFORE_EXIT", "3"))
VISIBILITY_EXTEND_INTERVAL = int(os.environ.get("VISIBILITY_EXTEND_INTERVAL", "300"))  # 5 min

s3 = boto3.client(
    "s3",
    region_name=REGION,
    config=Config(
        max_pool_connections=50,  # Increased for higher concurrency
        s3={
            "addressing_style": "virtual",
            "use_accelerate_endpoint": False,
            "payload_signing_enabled": True
        },
        connect_timeout=10,
        read_timeout=900,  # 15 minutes for large parts
        retries={
            "max_attempts": 5,
            "mode": "adaptive"
        }
    )
)
sqs = boto3.client("sqs", region_name=REGION)

FIVE_GB = 5 * 1024**3
shutdown_flag = False

def log(msg: str):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

def handle_sigterm(signum, frame):
    """Handle SIGTERM from Fargate Spot interruption"""
    global shutdown_flag
    log("⚠️  SIGTERM received (Fargate Spot interruption)")
    log("Gracefully shutting down - current message will be returned to queue")
    shutdown_flag = True

signal.signal(signal.SIGTERM, handle_sigterm)

def key_ok(key: str) -> bool:
    return (not PREFIX_FILTER) or key.startswith(PREFIX_FILTER)

def extend_visibility(receipt_handle: str):
    """Extend message visibility timeout to prevent message from becoming visible again"""
    try:
        sqs.change_message_visibility(
            QueueUrl=QUEUE_URL,
            ReceiptHandle=receipt_handle,
            VisibilityTimeout=VISIBILITY_TIMEOUT
        )
        log(f"  🔄 Extended visibility timeout by {VISIBILITY_TIMEOUT}s")
    except ClientError as e:
        log(f"  ⚠️  Failed to extend visibility: {e}")

def copy_to_dst(key: str, receipt_handle: str):
    """Copy object from source to destination, extending visibility for large files"""
    log(f"Copying: s3://{SRC_BUCKET}/{key} -> s3://{DST_BUCKET}/{key}")

    try:
        # Verify source object exists (idempotency check)
        try:
            head = s3.head_object(Bucket=SRC_BUCKET, Key=key)
        except ClientError as e:
            if e.response['Error']['Code'] == '404':
                log(f"  ⚠️  Source object not found (may have been deleted): {key}")
                return True  # Treat as success - idempotent
            raise

        size = head.get("ContentLength", 0)
        log(f"  Size: {size:,} bytes ({size / (1024**3):.2f} GB)")

        copy_source = {"Bucket": SRC_BUCKET, "Key": key}
        last_extend = time.time()

        if size >= FIVE_GB:
            log(f"  Using multipart copy for large file")
            _multipart_copy(copy_source, DST_BUCKET, key, receipt_handle, last_extend)
        else:
            # For smaller files, just extend once before copy
            if time.time() - last_extend > VISIBILITY_EXTEND_INTERVAL:
                extend_visibility(receipt_handle)
            s3.copy_object(CopySource=copy_source, Bucket=DST_BUCKET, Key=key)

        log(f"  ✅ Copy complete: {key}")
        return True

    except ClientError as e:
        log(f"  ❌ Copy failed: {e}")
        return False
    except Exception as e:
        log(f"  ❌ Unexpected error: {e}")
        return False

def _upload_part(copy_source, dest_bucket, dest_key, mpu_id, part_num, bytes_range):
    """Upload a single part (used by parallel executor)"""
    part = s3.upload_part_copy(
        CopySource=copy_source,
        Bucket=dest_bucket,
        Key=dest_key,
        PartNumber=part_num,
        UploadId=mpu_id,
        CopySourceRange=bytes_range
    )
    return {"PartNumber": part_num, "ETag": part["CopyPartResult"]["ETag"]}

def _multipart_copy(copy_source, dest_bucket, dest_key, receipt_handle, last_extend):
    """Multipart copy with parallel part uploads"""
    mpu = s3.create_multipart_upload(Bucket=dest_bucket, Key=dest_key)
    mpu_id = mpu["UploadId"]

    try:
        head = s3.head_object(**copy_source)
        size = head["ContentLength"]
        part_size = 64 * 1024 * 1024  # 64MB for testing with higher concurrency

        # Calculate all parts upfront
        part_jobs = []
        part_num = 1
        bytes_copied = 0

        while bytes_copied < size:
            bytes_range = f"bytes={bytes_copied}-{min(bytes_copied + part_size - 1, size - 1)}"
            part_jobs.append((part_num, bytes_range, bytes_copied, min(bytes_copied + part_size, size)))
            part_num += 1
            bytes_copied += part_size

        # Upload parts in parallel
        parts = []
        max_workers = 256  # 256 concurrent uploads for maximum throughput (~5.5 Gbps)

        log(f"  Uploading {len(part_jobs)} parts in parallel (max {max_workers} concurrent)...")

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # Submit all jobs
            future_to_part = {
                executor.submit(_upload_part, copy_source, dest_bucket, dest_key, mpu_id, pn, br): (pn, start, end)
                for pn, br, start, end in part_jobs
            }

            completed = 0
            for future in as_completed(future_to_part):
                part_num, start, end = future_to_part[future]

                # Check for shutdown signal
                if shutdown_flag:
                    log("  ⚠️  Shutdown signal received during multipart copy")
                    executor.shutdown(wait=False, cancel_futures=True)
                    s3.abort_multipart_upload(Bucket=dest_bucket, Key=dest_key, UploadId=mpu_id)
                    raise Exception("Shutdown signal received")

                # Check if we need to extend visibility
                if time.time() - last_extend > VISIBILITY_EXTEND_INTERVAL:
                    extend_visibility(receipt_handle)
                    last_extend = time.time()

                try:
                    part_result = future.result()
                    parts.append(part_result)
                    completed += 1
                    if completed % 5 == 0 or completed == len(part_jobs):
                        log(f"    Progress: {completed}/{len(part_jobs)} parts ({completed*100//len(part_jobs)}%)")
                except Exception as e:
                    log(f"  ❌ Part {part_num} failed: {e}")
                    raise

        # Sort parts by part number before completing
        parts.sort(key=lambda x: x["PartNumber"])

        s3.complete_multipart_upload(
            Bucket=dest_bucket,
            Key=dest_key,
            UploadId=mpu_id,
            MultipartUpload={"Parts": parts}
        )
    except Exception as e:
        log(f"  ⚠️  Aborting multipart upload due to error")
        s3.abort_multipart_upload(Bucket=dest_bucket, Key=dest_key, UploadId=mpu_id)
        raise

def delete_from_dst(key: str):
    """Delete object from destination (idempotent operation)"""
    log(f"Deleting: s3://{DST_BUCKET}/{key}")
    try:
        s3.delete_object(Bucket=DST_BUCKET, Key=key)
        log(f"  ✅ Delete complete: {key}")
        return True
    except ClientError as e:
        log(f"  ❌ Delete failed: {e}")
        return False

def process_message(msg: dict, receipt_handle: str) -> bool:
    """Process a single SQS message containing S3 event(s)"""
    try:
        body = msg.get("Body", "")
        s3evt = json.loads(body)

        for r in s3evt.get("Records", []):
            if shutdown_flag:
                log("⚠️  Shutdown signal received, stopping message processing")
                return False

            event_name = r.get("eventName", "")
            bucket = r.get("s3", {}).get("bucket", {}).get("name", "")
            key = r.get("s3", {}).get("object", {}).get("key", "")
            key = urllib.parse.unquote_plus(key)

            if bucket != SRC_BUCKET:
                log(f"Skipping event from different bucket: {bucket}")
                continue

            if not key_ok(key):
                log(f"Skipping key outside prefix filter: {key}")
                continue

            log(f"Processing event: {event_name} for key: {key}")

            if event_name.startswith("ObjectCreated:"):
                if not copy_to_dst(key, receipt_handle):
                    return False
            elif event_name.startswith("ObjectRemoved:"):
                if not delete_from_dst(key):
                    return False
            else:
                log(f"Unknown event type: {event_name}")

        return True
    except Exception as e:
        log(f"❌ Error processing message: {e}")
        return False

def worker_loop():
    log("Worker starting...")
    log(f"  Region: {REGION}")
    log(f"  Source bucket: {SRC_BUCKET}")
    log(f"  Destination bucket: {DST_BUCKET}")
    log(f"  Queue URL: {QUEUE_URL}")
    log(f"  Prefix filter: {PREFIX_FILTER or '<all>'}")
    log(f"  Visibility timeout: {VISIBILITY_TIMEOUT}s")
    log(f"  Long poll wait time: {WAIT_TIME_SECONDS}s")
    log(f"  Empty polls before exit: {EMPTY_POLLS_BEFORE_EXIT}")
    log(f"  Visibility extend interval: {VISIBILITY_EXTEND_INTERVAL}s")
    log("")

    messages_processed = 0
    consecutive_empty_polls = 0

    while not shutdown_flag:
        try:
            response = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=WAIT_TIME_SECONDS,
                VisibilityTimeout=VISIBILITY_TIMEOUT,
            )

            messages = response.get("Messages", [])

            if not messages:
                consecutive_empty_polls += 1
                log(f"No messages (empty poll {consecutive_empty_polls}/{EMPTY_POLLS_BEFORE_EXIT})...")

                if consecutive_empty_polls >= EMPTY_POLLS_BEFORE_EXIT:
                    log(f"✅ Queue empty after {EMPTY_POLLS_BEFORE_EXIT} consecutive polls")
                    log(f"✅ Processed {messages_processed} messages total")
                    log("Shutting down gracefully...")
                    sys.exit(0)
                continue

            # Reset counter when we get a message
            consecutive_empty_polls = 0

            for msg in messages:
                receipt_handle = msg["ReceiptHandle"]
                log(f"\n{'='*60}")
                log(f"Received message: {msg['MessageId']}")

                success = process_message(msg, receipt_handle)

                if success and not shutdown_flag:
                    # Only delete if processing succeeded AND we're not shutting down
                    sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
                    log(f"✅ Message deleted from queue (processed successfully)")
                    messages_processed += 1
                elif shutdown_flag:
                    log(f"⚠️  Message NOT deleted - returning to queue due to shutdown")
                else:
                    log(f"❌ Message processing failed - will retry after visibility timeout")

                log(f"{'='*60}\n")

        except KeyboardInterrupt:
            log(f"Worker interrupted... (processed {messages_processed} messages)")
            sys.exit(0)
        except Exception as e:
            log(f"❌ Unexpected error in worker loop: {e}")
            time.sleep(5)

    # Shutdown flag was set
    log(f"Worker shutting down gracefully... (processed {messages_processed} messages)")
    sys.exit(0)

if __name__ == "__main__":
    worker_loop()
