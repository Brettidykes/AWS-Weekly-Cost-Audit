#!/bin/bash

# Enhanced Weekly AWS Cost Analysis - 8 weeks with Month-over-Month Service Analysis
# CloudShell compatible version

set -e

# Configuration
WEEKS_TO_COMPARE=8  # 8 weeks = ~2 months for month-over-month comparison
ANOMALY_THRESHOLD=25
COST_THRESHOLD=10
WEEKLY_SPIKE_THRESHOLD=20  # Lowered from 50% to 20%
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

# Function to check if a week contains the 1st of any month
week_contains_first() {
    local start_date=$1
    local end_date=$2
    
    # Check each day in the week
    current_date="$start_date"
    while [ "$current_date" != "$(date -d "$end_date + 1 day" +%Y-%m-%d)" ]; do
        day=$(date -d "$current_date" +%d)
        if [ "$day" = "01" ]; then
            echo "$current_date"
            return 0
        fi
        current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
    done
    echo ""
    return 1
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

# Month-over-month comparison (last 4 weeks vs previous 4 weeks)
recent_month_total=0
for i in $(seq 0 3); do
    recent_month_total=$(awk "BEGIN {print $recent_month_total + ${week_totals[$i]}}")
done

previous_month_total=0
for i in $(seq 4 7); do
    previous_month_total=$(awk "BEGIN {print $previous_month_total + ${week_totals[$i]}}")
done

mom_change=$(awk "BEGIN {printf \"%.2f\", $recent_month_total - $previous_month_total}")
mom_percent=$(awk "BEGIN {printf \"%.2f\", ($mom_change / $previous_month_total) * 100}")

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
echo -e "${CYAN}MONTH-OVER-MONTH (Last 4 weeks vs Previous 4 weeks):${NC}"
printf "${BLUE}Recent Month:${NC}        \$%.2f\n" "$recent_month_total"
printf "${BLUE}Previous Month:${NC}      \$%.2f\n" "$previous_month_total"

mom_high=$(awk "BEGIN {print ($mom_percent > 10) ? 1 : 0}")
mom_low=$(awk "BEGIN {print ($mom_percent < -10) ? 1 : 0}")

if [ "$mom_high" -eq 1 ]; then
    printf "${RED}Month-over-Month:${NC}    +\$%.2f (+%.2f%%) ⚠${NC}\n" "$mom_change" "$mom_percent"
elif [ "$mom_low" -eq 1 ]; then
    printf "${GREEN}Month-over-Month:${NC}    \$%.2f (%.2f%%) ✓${NC}\n" "$mom_change" "$mom_percent"
else
    printf "${YELLOW}Month-over-Month:${NC}    \$%.2f (%.2f%%)${NC}\n" "$mom_change" "$mom_percent"
fi

echo ""
echo "================================================"
echo ""

# WEEKLY ANOMALY DETECTION WITH AUTOMATIC DRILL-DOWN
echo -e "${RED}⚠ WEEKLY COST SPIKES/DROPS (threshold: ±${WEEKLY_SPIKE_THRESHOLD}%)${NC}"
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
        
        # Check if this week contains the 1st of a month
        first_date=$(week_contains_first "$start" "$end")
        
        # Display the spike/drop header
        if [ "$is_spike" -eq 1 ]; then
            if [ $i -eq 0 ]; then
                echo -e "${RED}🔥 SPIKE - Most Recent Week${NC} ($start to $end)"
            else
                echo -e "${RED}🔥 SPIKE - Week -$i${NC} ($start to $end)"
            fi
            printf "   Cost: ${RED}\$%.2f${NC} | Median: \$%.2f | ${RED}+\$%.2f (+%.2f%%)${NC}\n" "$week_total" "$median" "$diff_from_median" "$pct_from_median"
            
            # Note if week contains 1st of month
            if [ -n "$first_date" ]; then
                month_name=$(date -d "$first_date" +%B)
                echo -e "   ${YELLOW}📅 NOTE: This week contains $month_name 1st ($first_date)${NC}"
                echo -e "   ${YELLOW}   Monthly AWS Support charges are typically billed on the 1st${NC}"
            fi
        else
            if [ $i -eq 0 ]; then
                echo -e "${GREEN}📉 DROP - Most Recent Week${NC} ($start to $end)"
            else
                echo -e "${GREEN}📉 DROP - Week -$i${NC} ($start to $end)"
            fi
            printf "   Cost: ${GREEN}\$%.2f${NC} | Median: \$%.2f | ${GREEN}\$%.2f (%.2f%%)${NC}\n" "$week_total" "$median" "$diff_from_median" "$pct_from_median"
            
            if [ -n "$first_date" ]; then
                month_name=$(date -d "$first_date" +%B)
                echo -e "   ${YELLOW}📅 NOTE: This week contains $month_name 1st ($first_date)${NC}"
            fi
        fi
        
        echo ""
        echo -e "   ${CYAN}📅 DAILY BREAKDOWN:${NC}"
        echo "   ----------------------------------------"
        
        # Show daily costs for this week
        echo "${week_data[$i]}" | jq -r '.ResultsByTime[] | "\(.TimePeriod.Start)|\([.Groups[].Metrics.UnblendedCost.Amount | tonumber] | add)"' | \
        while IFS='|' read day_date day_total; do
            day_name=$(date -d "$day_date" +%A)
            day_formatted=$(date -d "$day_date" +"%b %d")
            
            # Check if this is the 1st of the month
            day_num=$(date -d "$day_date" +%d)
            if [ "$day_num" = "01" ]; then
                printf "   ${YELLOW}%-10s %-10s \$%8.2f  ← 1st of month${NC}\n" "$day_name" "$day_formatted" "$day_total"
            else
                printf "   %-10s %-10s \$%8.2f\n" "$day_name" "$day_formatted" "$day_total"
            fi
        done
        
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
        
        # Calculate baseline for each service
        echo "$anomalous_services" | jq -r '.[] | "\(.service)|\(.cost)"' | while IFS='|' read service spike_week_cost; do
            
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
            
            service_diff=$(awk "BEGIN {printf \"%.2f\", $spike_week_cost - $avg_baseline}")
            
            abs_diff=$(awk "BEGIN {
                diff = $service_diff
                if (diff < 0) {
                    print -diff
                } else {
                    print diff
                }
            }")
            
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

# SERVICE-LEVEL MONTH-OVER-MONTH CHANGES
echo -e "${MAGENTA}📊 SERVICE-LEVEL MONTH-OVER-MONTH ANALYSIS${NC}"
echo -e "${MAGENTA}(Recent 4 weeks vs Previous 4 weeks)${NC}"
echo "================================================"

all_services=$(for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do 
    echo "${week_data[$i]}" | jq -r '[.ResultsByTime[].Groups[].Keys[0]] | .[]'
done | sort -u)

echo "$all_services" | while read service; do
    recent_service_total=0
    for i in $(seq 0 3); do
        cost=$(echo "${week_data[$i]}" | jq -r --arg svc "$service" '
            [.ResultsByTime[].Groups[] | select(.Keys[0] == $svc) | .Metrics.UnblendedCost.Amount | tonumber] | add // 0')
        recent_service_total=$(awk "BEGIN {print $recent_service_total + $cost}")
    done
    
    prev_service_total=0
    for i in $(seq 4 7); do
        cost=$(echo "${week_data[$i]}" | jq -r --arg svc "$service" '
            [.ResultsByTime[].Groups[] | select(.Keys[0] == $svc) | .Metrics.UnblendedCost.Amount | tonumber] | add // 0')
        prev_service_total=$(awk "BEGIN {print $prev_service_total + $cost}")
    done
    
    service_mom_diff=$(awk "BEGIN {printf \"%.2f\", $recent_service_total - $prev_service_total}")
    
    abs_service_diff=$(awk "BEGIN {
        diff = $service_mom_diff
        if (diff < 0) {
            print -diff
        } else {
            print diff
        }
    }")
    
    significant=$(awk "BEGIN {print ($abs_service_diff > 20) ? 1 : 0}")
    
    if [ "$significant" -eq 1 ]; then
        if (( $(awk "BEGIN {print ($prev_service_total > 0) ? 1 : 0}") )); then
            service_mom_pct=$(awk "BEGIN {printf \"%.1f\", ($service_mom_diff / $prev_service_total) * 100}")
            
            if (( $(awk "BEGIN {print ($service_mom_diff > 0) ? 1 : 0}") )); then
                printf "${RED}↑ %-45s${NC} \$%8.2f → \$%8.2f ${RED}(+\$%.2f, +%.1f%%)${NC}\n" \
                    "$service" "$prev_service_total" "$recent_service_total" "$service_mom_diff" "$service_mom_pct"
            else
                printf "${GREEN}↓ %-45s${NC} \$%8.2f → \$%8.2f ${GREEN}(\$%.2f, %.1f%%)${NC}\n" \
                    "$service" "$prev_service_total" "$recent_service_total" "$service_mom_diff" "$service_mom_pct"
            fi
        else
            if (( $(awk "BEGIN {print ($recent_service_total > 20) ? 1 : 0}") )); then
                printf "${YELLOW}⚡ %-45s${NC} \$%8.2f ${YELLOW}(NEW in recent month)${NC}\n" "$service" "$recent_service_total"
            fi
        fi
    fi
done

echo ""
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

# ========== REPORT GENERATION SECTION ==========

# Generate full detailed report file
REPORT_FILE="$OUTPUT_DIR/detailed_cost_report_$DATE.txt"

{
    echo "================================================"
    echo "AWS WEEKLY COST ANALYSIS - DETAILED REPORT"
    echo "Generated: $(date)"
    echo "================================================"
    echo ""
    echo "EXECUTIVE SUMMARY"
    echo "-----------------"
    printf "Most Recent Week: \$%.2f (%s to %s)\n" "$current_total" "$most_recent_start" "$most_recent_end"
    printf "Previous Week: \$%.2f\n" "$prev_week_total"
    printf "Week-over-Week: \$%.2f (%.2f%%)\n" "$wow_change" "$wow_percent"
    echo ""
    printf "Average: \$%.2f | Median: \$%.2f\n" "$avg_previous" "$median"
    printf "Recent Month: \$%.2f | Previous Month: \$%.2f\n" "$recent_month_total" "$previous_month_total"
    printf "Month-over-Month: \$%.2f (%.2f%%)\n" "$mom_change" "$mom_percent"
    echo ""
    
    echo "WEEKLY TREND"
    echo "------------"
    for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do
        IFS='|' read start end <<< "${week_dates[$i]}"
        printf "Week -%d (%s to %s): \$%.2f\n" "$i" "$start" "$end" "${week_totals[$i]}"
    done
    echo ""
    
    echo "TOP 10 SERVICES"
    echo "---------------"
    echo "${week_data[0]}" | jq -r '
        [.ResultsByTime[].Groups[]] | 
        group_by(.Keys[0]) | 
        map({service: .[0].Keys[0], cost: (map(.Metrics.UnblendedCost.Amount | tonumber) | add)}) | 
        sort_by(-.cost) | .[:10] | .[] | "\(.service): $\(.cost)"'
} > "$REPORT_FILE"

# Generate CSV
CSV_FILE="$OUTPUT_DIR/service_costs_$DATE.csv"
{
    printf "Service"
    for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do printf ",Week_%d" "$i"; done
    echo ""
    
    all_svcs=$(for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do 
        echo "${week_data[$i]}" | jq -r '[.ResultsByTime[].Groups[].Keys[0]] | .[]'
    done | sort -u)
    
    echo "$all_svcs" | while read svc; do
        printf "%s" "$svc"
        for i in $(seq 0 $((WEEKS_TO_COMPARE - 1))); do
            cost=$(echo "${week_data[$i]}" | jq -r --arg s "$svc" '
                [.ResultsByTime[].Groups[] | select(.Keys[0] == $s) | .Metrics.UnblendedCost.Amount | tonumber] | add // 0')
            printf ",%.2f" "$cost"
        done
        echo ""
    done
} > "$CSV_FILE"

echo "📊 Detailed report saved: $REPORT_FILE"
echo "📈 CSV export saved: $CSV_FILE"
echo ""
