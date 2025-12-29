#!/usr/bin/env python3
"""
Starter Lambda - checks SQS queue and starts ECS Fargate Spot tasks on-demand
Triggered by EventBridge every 1-5 minutes
"""
import os
import math
import boto3

REGION = os.environ["REGION"]
QUEUE_URL = os.environ["QUEUE_URL"]
CLUSTER = os.environ["CLUSTER"]
TASK_DEFINITION = os.environ["TASK_DEFINITION"]
SUBNETS = os.environ["SUBNETS"].split(",")  # Comma-separated subnet IDs
SECURITY_GROUPS = os.environ.get("SECURITY_GROUPS", "").split(",") if os.environ.get("SECURITY_GROUPS") else []
MAX_WORKERS = int(os.environ.get("MAX_WORKERS", "2"))

# Backlog-per-task scaling strategy to avoid burst and smooth S3 request spikes
TARGET_BACKLOG_PER_TASK = int(os.environ.get("TARGET_BACKLOG_PER_TASK", "3"))
BURST_START_LIMIT = int(os.environ.get("BURST_START_LIMIT", "10"))

sqs = boto3.client("sqs", region_name=REGION)
ecs = boto3.client("ecs", region_name=REGION)

def get_queue_depth():
    """Get total messages in queue (visible + in-flight)"""
    resp = sqs.get_queue_attributes(
        QueueUrl=QUEUE_URL,
        AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
    )
    attrs = resp["Attributes"]
    visible = int(attrs.get("ApproximateNumberOfMessages", 0))
    not_visible = int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0))
    total = visible + not_visible
    return visible, not_visible, total

def get_running_tasks():
    """Get count of running + pending tasks"""
    running = ecs.list_tasks(cluster=CLUSTER, desiredStatus="RUNNING")
    pending = ecs.list_tasks(cluster=CLUSTER, desiredStatus="PENDING")
    return len(running.get("taskArns", [])) + len(pending.get("taskArns", []))

def start_task():
    """Start a single Fargate Spot task"""
    network_config = {
        "awsvpcConfiguration": {
            "subnets": SUBNETS,
            "assignPublicIp": "ENABLED"
        }
    }

    if SECURITY_GROUPS and SECURITY_GROUPS[0]:
        network_config["awsvpcConfiguration"]["securityGroups"] = SECURITY_GROUPS

    resp = ecs.run_task(
        cluster=CLUSTER,
        taskDefinition=TASK_DEFINITION,
        capacityProviderStrategy=[
            {
                "capacityProvider": "FARGATE_SPOT",
                "weight": 4,
                "base": 0
            },
            {
                "capacityProvider": "FARGATE",
                "weight": 1,
                "base": 0
            }
        ],
        networkConfiguration=network_config,
        enableExecuteCommand=False,
        count=1
    )

    if resp.get("tasks"):
        task_arn = resp["tasks"][0]["taskArn"]
        return task_arn
    elif resp.get("failures"):
        raise Exception(f"Failed to start task: {resp['failures']}")
    else:
        raise Exception("Unknown error starting task")

def handler(event, context):
    """Lambda handler - check queue and start tasks as needed"""
    print(f"Checking queue: {QUEUE_URL}")

    visible, not_visible, queue_depth = get_queue_depth()
    running_tasks = get_running_tasks()

    print(f"Queue: {visible} visible, {not_visible} in-flight, {queue_depth} total")
    print(f"Running tasks: {running_tasks}/{MAX_WORKERS}")
    print(f"Scaling strategy: TARGET_BACKLOG_PER_TASK={TARGET_BACKLOG_PER_TASK}, BURST_START_LIMIT={BURST_START_LIMIT}")

    if queue_depth == 0:
        print("No messages in queue - no action needed")
        return {
            "statusCode": 200,
            "body": "No messages in queue"
        }

    if running_tasks >= MAX_WORKERS:
        print(f"Already at max capacity ({MAX_WORKERS} tasks)")
        return {
            "statusCode": 200,
            "body": f"At max capacity: {running_tasks}/{MAX_WORKERS}"
        }

    # Calculate how many tasks to start using backlog-per-task strategy
    # This avoids burst and smooths S3 request spikes
    desired_tasks = math.ceil(queue_depth / TARGET_BACKLOG_PER_TASK)
    tasks_needed = max(0, desired_tasks - running_tasks)

    # Apply burst limit to avoid sudden spikes (gradual ramp-up)
    tasks_needed = min(
        tasks_needed,
        MAX_WORKERS - running_tasks,
        BURST_START_LIMIT
    )

    print(f"Backlog calculation: {queue_depth} messages ÷ {TARGET_BACKLOG_PER_TASK} per task = {desired_tasks} desired tasks")
    print(f"Starting {tasks_needed} task(s) (burst limit: {BURST_START_LIMIT})...")

    started = []
    for i in range(tasks_needed):
        try:
            task_arn = start_task()
            started.append(task_arn)
            print(f"  Started task {i+1}/{tasks_needed}: {task_arn.split('/')[-1]}")
        except Exception as e:
            print(f"  Failed to start task {i+1}: {e}")
            break

    return {
        "statusCode": 200,
        "body": f"Started {len(started)} task(s)",
        "tasksStarted": len(started),
        "queueDepth": queue_depth,
        "runningTasks": running_tasks
    }

if __name__ == "__main__":
    # For local testing
    import sys
    result = handler({}, None)
    print(f"\nResult: {result}")
    sys.exit(0 if result["statusCode"] == 200 else 1)
