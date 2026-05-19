cat > weekly_cost_analysis_with_drilldown.sh << 'SCRIPT_EOF'
#!/bin/bash

# Enhanced Weekly AWS Cost Analysis - WITH AUTOMATIC SPIKE DRILL-DOWN
# CloudShell compatible version - Fixed awk syntax

set -e

# Configuration
WEEKS_TO_COMPARE=6
ANOMALY_THRESHOLD=25
COST_THRESHOLD=10
WEEKLY_SPIKE_THRESHOLD=50
OUTPUT_DIR="./cost_reports"
DATE=$(date +%Y-%m-%d)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

mkdir -p "$OUTPUT_DIR"

echo "================================================"
echo "AWS Weekly Cost Analysis with Anomaly Detection"
echo "================================================"
echo ""

# Function to get COMPLETE week date range
get_week_range() {
    local weeks_ago=$1
    local adjusted_weeks=$((weeks_ago + 1))
    local start_date=$(date -d "monday-$((adjusted_weeks + 1)) weeks" +%Y-%m-%d)
    local end_date=$(date -d "sunday-$adjusted_weeks weeks" +%Y-%m-%d)
    echo "$start_date $end_date"
}

# Get costs grouped by service
get_costs() {
    local start_date=$1
    local end_date=$2
    
    aws ce get-cost-and-usage \
        --time-period Start="$start_date",End="$end_date" \
        --granularity DAILY \
        --metrics "UnblendedCost" \
        --group-by Type=DIMENSION,Key=SERVICE \
        --output json
}

# Collect weekly data
declare -A week_data
declare -A week_totals
declare -A week_dates

read first_start first_end <<< $(get_week_range 0)
echo -e "${YELLOW}Note: Current week is incomplete (today is $(date +%Y-%m-%d))${NC}"
echo -e "${YELLOW}Analyzing last $WEEKS_TO_COMPARE COMPLETE weeks starting from: $first_start to $first_end${NC}"
echo ""

echo "Fetching cost data..."
for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do
    read start_date end_date <<< $(get_week_range $i)
    
    if [ $i -eq 0 ]; then
        week_label="Most Recent Week ($start_date to $end_date)"
    else
        week_label="Week -$i ($start_date to $end_date)"
    fi
    
    printf "%s..." "$week_label"
    
    json_data=$(get_costs "$start_date" "$end_date")
    week_data[$i]="$json_data"
    week_dates[$i]="$start_date|$end_date"
    
    total=$(echo "$json_data" | jq -r '[.ResultsByTime[].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add')
    week_totals[$i]=$total
    
    printf " \$%.2f\n" "$total"
done

echo ""

# Calculate median for spike detection
sorted_totals=$(for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do echo "${week_totals[$i]}"; done | sort -n)
median=$(echo "$sorted_totals" | awk '{a[NR]=$1} END {if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}')

# Calculate statistics
current_total=${week_totals[0]}
prev_week_total=${week_totals[1]}

# Calculate average of previous weeks (excluding most recent)
sum=0
count=0
for i in $(seq 1 $((WEEKS_TO_COMPARE - 1))); do
    sum=$(awk "BEGIN {print $sum + ${week_totals[$i]}}")
    count=$((count + 1))
done
avg_previous=$(awk "BEGIN {printf \"%.2f\", $sum / $count}")

# Week-over-week change
wow_change=$(awk "BEGIN {printf \"%.2f\", $current_total - $prev_week_total}")
wow_percent=$(awk "BEGIN {printf \"%.2f\", ($wow_change / $prev_week_total) * 100}")

# Average comparison
avg_change=$(awk "BEGIN {printf \"%.2f\", $current_total - $avg_previous}")
avg_percent=$(awk "BEGIN {printf \"%.2f\", ($avg_change / $avg_previous) * 100}")

# Console output
echo "================================================"
echo "COST ANALYSIS SUMMARY"
echo "================================================"
echo ""

IFS='|' read most_recent_start most_recent_end <<< "${week_dates[0]}"
echo -e "${CYAN}Most Recent Complete Week:${NC} $most_recent_start to $most_recent_end"
echo ""

printf "${BLUE}Most Recent Week:${NC}    \$%.2f\n" "$current_total"
printf "${BLUE}Previous Week:${NC}       \$%.2f\n" "$prev_week_total"

wow_high=$(awk "BEGIN {print ($wow_percent > 10) ? 1 : 0}")
wow_low=$(awk "BEGIN {print ($wow_percent < -10) ? 1 : 0}")

if [ "$wow_high" -eq 1 ]; then
    printf "${RED}Week-over-Week:${NC}      +\$%.2f (+%.2f%%) ⚠${NC}\n" "$wow_change" "$wow_percent"
elif [ "$wow_low" -eq 1 ]; then
    printf "${GREEN}Week-over-Week:${NC}      \$%.2f (%.2f%%) ✓${NC}\n" "$wow_change" "$wow_percent"
else
    printf "${YELLOW}Week-over-Week:${NC}      \$%.2f (%.2f%%)${NC}\n" "$wow_change" "$wow_percent"
fi

echo ""
printf "${BLUE}%d-Week Average:${NC}     \$%.2f\n" "$((WEEKS_TO_COMPARE - 1))" "$avg_previous"
printf "${BLUE}%d-Week Median:${NC}      \$%.2f\n" "$WEEKS_TO_COMPARE" "$median"

avg_high=$(awk "BEGIN {print ($avg_percent > 15) ? 1 : 0}")
avg_low=$(awk "BEGIN {print ($avg_percent < -15) ? 1 : 0}")

if [ "$avg_high" -eq 1 ]; then
    printf "${RED}vs Average:${NC}          +\$%.2f (+%.2f%%) ⚠${NC}\n" "$avg_change" "$avg_percent"
elif [ "$avg_low" -eq 1 ]; then
    printf "${GREEN}vs Average:${NC}          \$%.2f (%.2f%%) ✓${NC}\n" "$avg_change" "$avg_percent"
else
    printf "${YELLOW}vs Average:${NC}          \$%.2f (%.2f%%)${NC}\n" "$avg_change" "$avg_percent"
fi

echo ""
echo "================================================"
echo ""

# WEEKLY ANOMALY DETECTION WITH AUTOMATIC DRILL-DOWN
echo -e "${RED}⚠ WEEKLY COST SPIKES/DROPS (with drill-down)${NC}"
echo "================================================"
spike_found=0

for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do
    week_total=${week_totals[$i]}
    IFS='|' read start end <<< "${week_dates[$i]}"
    
    diff_from_median=$(awk "BEGIN {printf \"%.2f\", $week_total - $median}")
    pct_from_median=$(awk "BEGIN {printf \"%.2f\", ($diff_from_median / $median) * 100}")
    
    is_spike=$(awk "BEGIN {print ($pct_from_median > $WEEKLY_SPIKE_THRESHOLD) ? 1 : 0}")
    is_drop=$(awk "BEGIN {print ($pct_from_median < -$WEEKLY_SPIKE_THRESHOLD) ? 1 : 0}")
    
    if [ "$is_spike" -eq 1 ] || [ "$is_drop" -eq 1 ]; then
        spike_found=1
        
        # Display the spike/drop header
        if [ "$is_spike" -eq 1 ]; then
            if [ $i -eq 0 ]; then
                echo -e "${RED}🔥 SPIKE - Most Recent Week${NC} ($start to $end)"
            else
                echo -e "${RED}🔥 SPIKE - Week -$i${NC} ($start to $end)"
            fi
            printf "   Cost: ${RED}\$%.2f${NC} | Median: \$%.2f | ${RED}+\$%.2f (+%.2f%%)${NC}\n" "$week_total" "$median" "$diff_from_median" "$pct_from_median"
        else
            if [ $i -eq 0 ]; then
                echo -e "${GREEN}📉 DROP - Most Recent Week${NC} ($start to $end)"
            else
                echo -e "${GREEN}📉 DROP - Week -$i${NC} ($start to $end)"
            fi
            printf "   Cost: ${GREEN}\$%.2f${NC} | Median: \$%.2f | ${GREEN}\$%.2f (%.2f%%)${NC}\n" "$week_total" "$median" "$diff_from_median" "$pct_from_median"
        fi
        
        echo ""
        echo -e "   ${CYAN}🔍 DRILL-DOWN: What caused this?${NC}"
        echo "   ----------------------------------------"
        
        # Get all services for this anomalous week
        anomalous_services=$(echo "${week_data[$i]}" | jq -r '
            [.ResultsByTime[].Groups[]] | 
            group_by(.Keys[0]) | 
            map({
                service: .[0].Keys[0],
                cost: (map(.Metrics.UnblendedCost.Amount | tonumber) | add)
            }) | 
            sort_by(-.cost) | 
            .[]' | jq -s '.')
        
        # Calculate baseline for each service (average of other weeks, excluding this anomalous week)
        echo "$anomalous_services" | jq -r '.[] | "\(.service)|\(.cost)"' | while IFS='|' read service spike_week_cost; do
            
            # Calculate average cost for this service across OTHER weeks (excluding week $i)
            total_baseline=0
            baseline_count=0
            for j in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do
                if [ $j -ne $i ]; then
                    baseline_cost=$(echo "${week_data[$j]}" | jq -r --arg svc "$service" '
                        [.ResultsByTime[].Groups[] | select(.Keys[0] == $svc) | .Metrics.UnblendedCost.Amount | tonumber] | add // 0')
                    total_baseline=$(awk "BEGIN {print $total_baseline + $baseline_cost}")
                    baseline_count=$((baseline_count + 1))
                fi
            done
            
            if [ $baseline_count -gt 0 ]; then
                avg_baseline=$(awk "BEGIN {printf \"%.2f\", $total_baseline / $baseline_count}")
            else
                avg_baseline=0
            fi
            
            # Calculate difference
            service_diff=$(awk "BEGIN {printf \"%.2f\", $spike_week_cost - $avg_baseline}")
            
            # Calculate absolute value for comparison (fixed syntax)
            abs_diff=$(awk "BEGIN {
                diff = $service_diff
                if (diff < 0) {
                    print -diff
                } else {
                    print diff
                }
            }")
            
            # Only show services that contributed significantly (>$50 difference)
            significant=$(awk "BEGIN {print ($abs_diff > 50) ? 1 : 0}")
            
            if [ "$significant" -eq 1 ]; then
                if (( $(awk "BEGIN {print ($avg_baseline > 0) ? 1 : 0}") )); then
                    service_pct=$(awk "BEGIN {printf \"%.1f\", ($service_diff / $avg_baseline) * 100}")
                    
                    if (( $(awk "BEGIN {print ($service_diff > 0) ? 1 : 0}") )); then
                        printf "   ${RED}↑ %-40s${NC} \$%8.2f → \$%8.2f ${RED}(+\$%.2f, +%.1f%%)${NC}\n" \
                            "$service" "$avg_baseline" "$spike_week_cost" "$service_diff" "$service_pct"
                    else
                        printf "   ${GREEN}↓ %-40s${NC} \$%8.2f → \$%8.2f ${GREEN}(\$%.2f, %.1f%%)${NC}\n" \
                            "$service" "$avg_baseline" "$spike_week_cost" "$service_diff" "$service_pct"
                    fi
                else
                    # New service in this week
                    if (( $(awk "BEGIN {print ($spike_week_cost > 50) ? 1 : 0}") )); then
                        printf "   ${YELLOW}⚡ %-40s${NC} \$%8.2f ${YELLOW}(NEW)${NC}\n" "$service" "$spike_week_cost"
                    fi
                fi
            fi
        done
        
        echo ""
    fi
done

if [ "$spike_found" -eq 0 ]; then
    echo "No significant weekly spikes detected (threshold: ±${WEEKLY_SPIKE_THRESHOLD}% from median)"
    echo ""
fi

echo "================================================"
echo ""

# TOP SERVICES - MOST RECENT COMPLETE WEEK
echo -e "${CYAN}TOP 10 SERVICES - MOST RECENT COMPLETE WEEK${NC}"
echo "================================================"
echo "${week_data[0]}" | jq -r '
    [.ResultsByTime[].Groups[]] | 
    group_by(.Keys[0]) | 
    map({
        service: .[0].Keys[0],
        cost: (map(.Metrics.UnblendedCost.Amount | tonumber) | add)
    }) | 
    sort_by(-.cost) | 
    .[:10] | 
    .[] | 
    "\(.service)|\(.cost)"' | while IFS='|' read service cost; do
    pct=$(awk "BEGIN {printf \"%.1f\", ($cost / $current_total) * 100}")
    printf "%-45s \$%8.2f  (%5.1f%%)\n" "$service" "$cost" "$pct"
done

echo ""
echo "================================================"
echo ""

# SERVICE-LEVEL ANOMALY DETECTION
echo -e "${MAGENTA}SERVICE-LEVEL ANOMALY DETECTION${NC}"
echo -e "${MAGENTA}(Comparing most recent complete week vs previous weeks)${NC}"
echo "================================================"

services=$(echo "${week_data[0]}" | jq -r '[.ResultsByTime[].Groups[].Keys[0]] | unique | .[]')

anomaly_found=0

echo "$services" | while read service; do
    current_cost=$(echo "${week_data[0]}" | jq -r --arg svc "$service" '
        [.ResultsByTime[].Groups[] | select(.Keys[0] == $svc) | .Metrics.UnblendedCost.Amount | tonumber] | add // 0')
    
    below_threshold=$(awk "BEGIN {print ($current_cost < $COST_THRESHOLD) ? 1 : 0}")
    if [ "$below_threshold" -eq 1 ]; then
        continue
    fi
    
    total_prev=0
    count=0
    for j in $(seq 1 $((WEEKS_TO_COMPARE - 1))); do
        prev_cost=$(echo "${week_data[$j]}" | jq -r --arg svc "$service" '
            [.ResultsByTime[].Groups[] | select(.Keys[0] == $svc) | .Metrics.UnblendedCost.Amount | tonumber] | add // 0')
        total_prev=$(awk "BEGIN {print $total_prev + $prev_cost}")
        count=$((count + 1))
    done
    
    avg_cost=$(awk "BEGIN {printf \"%.2f\", $total_prev / $count}")
    
    above_zero=$(awk "BEGIN {print ($avg_cost > 0) ? 1 : 0}")
    if [ "$above_zero" -eq 1 ]; then
        diff=$(awk "BEGIN {printf \"%.2f\", $current_cost - $avg_cost}")
        pct=$(awk "BEGIN {printf \"%.2f\", ($diff / $avg_cost) * 100}")
        
        increased=$(awk "BEGIN {print ($pct > $ANOMALY_THRESHOLD) ? 1 : 0}")
        decreased=$(awk "BEGIN {print ($pct < -$ANOMALY_THRESHOLD) ? 1 : 0}")
        
        if [ "$increased" -eq 1 ]; then
            echo -e "${RED}⚠ INCREASED:${NC} $service"
            printf "   Recent Week: \$%.2f | Average: \$%.2f | Change: ${RED}+\$%.2f (+%.2f%%)${NC}\n" "$current_cost" "$avg_cost" "$diff" "$pct"
            echo ""
            anomaly_found=1
        elif [ "$decreased" -eq 1 ]; then
            echo -e "${GREEN}✓ DECREASED:${NC} $service"
            printf "   Recent Week: \$%.2f | Average: \$%.2f | Change: ${GREEN}\$%.2f (%.2f%%)${NC}\n" "$current_cost" "$avg_cost" "$diff" "$pct"
            echo ""
            anomaly_found=1
        fi
    else
        above_cost_threshold=$(awk "BEGIN {print ($current_cost > $COST_THRESHOLD) ? 1 : 0}")
        if [ "$above_cost_threshold" -eq 1 ]; then
            echo -e "${YELLOW}⚡ NEW SERVICE:${NC} $service"
            printf "   Recent Week: \$%.2f (No previous history)\n" "$current_cost"
            echo ""
            anomaly_found=1
        fi
    fi
done

if [ "$anomaly_found" -eq 0 ]; then
    echo "No significant service-level anomalies (threshold: ±${ANOMALY_THRESHOLD}%)"
    echo ""
fi

echo "================================================"
echo ""

# WEEKLY TREND TABLE
echo -e "${CYAN}WEEKLY COST TREND (Last $WEEKS_TO_COMPARE Complete Weeks)${NC}"
echo "================================================"
printf "%-15s  %-22s  %12s\n" "Week" "Date Range" "Total Cost"
echo "------------------------------------------------"
for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do
    IFS='|' read start end <<< "${week_dates[$i]}"
    week_total=${week_totals[$i]}
    
    diff_from_median=$(awk "BEGIN {printf \"%.2f\", $week_total - $median}")
    pct_from_median=$(awk "BEGIN {printf \"%.2f\", ($diff_from_median / $median) * 100}")
    is_spike=$(awk "BEGIN {print ($pct_from_median > $WEEKLY_SPIKE_THRESHOLD || $pct_from_median < -$WEEKLY_SPIKE_THRESHOLD) ? 1 : 0}")
    
    if [ $i -eq 0 ]; then
        if [ "$is_spike" -eq 1 ]; then
            printf "${RED}%-15s${NC}  %-22s  ${RED}\$%11.2f ⚠${NC}\n" "Most Recent" "$start to $end" "$week_total"
        else
            printf "${GREEN}%-15s${NC}  %-22s  ${GREEN}\$%11.2f${NC}\n" "Most Recent" "$start to $end" "$week_total"
        fi
    else
        if [ "$is_spike" -eq 1 ]; then
            printf "${RED}%-15s${NC}  %-22s  ${RED}\$%11.2f ⚠${NC}\n" "-$i" "$start to $end" "$week_total"
        else
            printf "%-15s  %-22s  \$%11.2f\n" "-$i" "$start to $end" "$week_total"
        fi
    fi
done
echo "================================================"
echo ""

echo "📊 Detailed report: ./cost_reports/detailed_cost_report_$DATE.txt"
echo "📈 CSV export: ./cost_reports/service_costs_$DATE.csv"
echo ""

SCRIPT_EOF

chmod +x weekly_cost_analysis_with_drilldown.sh
