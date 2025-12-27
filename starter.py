#!/usr/bin/env python3
"""
Starter Lambda - checks SQS queue and starts ECS Fargate Spot tasks on-demand
Triggered by EventBridge every 1-5 minutes
"""
import os
import boto3

REGION = os.environ["REGION"]
QUEUE_URL = os.environ["QUEUE_URL"]
CLUSTER = os.environ["CLUSTER"]
TASK_DEFINITION = os.environ["TASK_DEFINITION"]
SUBNETS = os.environ["SUBNETS"].split(",")  # Comma-separated subnet IDs
SECURITY_GROUPS = os.environ.get("SECURITY_GROUPS", "").split(",") if os.environ.get("SECURITY_GROUPS") else []
MAX_WORKERS = int(os.environ.get("MAX_WORKERS", "2"))

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
    return visible + not_visible

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

    queue_depth = get_queue_depth()
    running_tasks = get_running_tasks()

    print(f"Queue depth: {queue_depth} messages")
    print(f"Running tasks: {running_tasks}/{MAX_WORKERS}")

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

    # Calculate how many tasks to start
    # Simple heuristic: 1 task per 10 messages (or remaining capacity)
    tasks_needed = min(
        MAX_WORKERS - running_tasks,
        max(1, (queue_depth + 9) // 10)  # Round up, min 1
    )

    print(f"Starting {tasks_needed} task(s)...")

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
