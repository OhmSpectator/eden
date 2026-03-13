# 1. Get all runs of the reusable Eden test suite (test.yml)
for run_id in $(gh run list --workflow=eden-trusted.yml --repo lf-edge/eve --limit 1000 --json databaseId | jq -r '.[].databaseId'); do
    echo Hanling $run_id
    # 2. For each run, get all jobs (e.g., Storage, Networking, etc.)
    for job_id in $(gh api repos/lf-edge/eve/actions/runs/$run_id/jobs | jq -r '.jobs[].id'); do
        job_name=$(gh api repos/lf-edge/eve/actions/jobs/$job_id | jq -r '.name')
	echo "  job: $job_name"
        log=$(gh run view --job "$job_id" --repo lf-edge/eve --log 2>/dev/null)
        ip=$(echo "$log" | grep -Eo 'Public IP Address of the runner:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        if [ -n "$ip" ]; then
            echo "Run $run_id, Job $job_id ($job_name): $ip"
        fi
    done
done

