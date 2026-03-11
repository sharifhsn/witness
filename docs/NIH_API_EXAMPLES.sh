#!/bin/bash
# NIH Reporter API v2 Examples for Grant Termination/Modification Analysis
# https://api.reporter.nih.gov/docs/API

# Base URL
API_BASE="https://api.reporter.nih.gov/v2"

# === Example 1: Find all inactive projects that ended between 2024-2026 ===
echo "Example 1: Inactive projects (2024-2026)"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "include_active_projects": false,
      "project_end_date": {
        "from_date": "2024-01-01",
        "to_date": "2026-03-10"
      }
    },
    "offset": 0,
    "limit": 50
  }' | jq '.meta'

# === Example 2: Find projects by specific grant number ===
echo -e "\n\nExample 2: Search by project number (with wildcard)"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "project_nums": ["5R01AI178795*"],
      "fiscal_years": [2024, 2025, 2026]
    },
    "offset": 0,
    "limit": 10
  }' | jq '.meta'

# === Example 3: Find grants that were recently added as inactive ===
echo -e "\n\nExample 3: Recently terminated projects (added to DB in past month)"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "include_active_projects": false,
      "date_added": {
        "from_date": "2026-02-10"
      }
    },
    "offset": 0,
    "limit": 50
  }' | jq '.meta'

# === Example 4: Track funding changes by agency ===
echo -e "\n\nExample 4: Inactive projects by specific agencies"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "agencies": ["NIAID", "NCI", "NIDDK"],
      "include_active_projects": false,
      "project_end_date": {
        "from_date": "2024-01-01"
      }
    },
    "offset": 0,
    "limit": 50
  }' | jq '.meta'

# === Example 5: Find grants with budget modifications ===
echo -e "\n\nExample 5: Inactive projects by award type and amount"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "include_active_projects": false,
      "activity_codes": ["R01", "R35"],
      "award_amount_range": {
        "min_amount": 1000000,
        "max_amount": 50000000
      },
      "project_end_date": {
        "from_date": "2024-01-01"
      }
    },
    "offset": 0,
    "limit": 50
  }' | jq '.meta'

# === Example 6: Find grants from specific institution ===
echo -e "\n\nExample 6: Inactive projects from specific institutions"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "include_active_projects": false,
      "org_names": ["HARVARD UNIVERSITY", "MIT"],
      "project_end_date": {
        "from_date": "2024-01-01"
      }
    },
    "offset": 0,
    "limit": 50
  }' | jq '.meta'

# === Example 7: Pagination with large result sets ===
echo -e "\n\nExample 7: Paginating through large result sets"
# Get first page
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "include_active_projects": false
    },
    "offset": 0,
    "limit": 500
  }' | jq '.meta.total'

# Get next page (offset by 500)
# curl -s -X POST "$API_BASE/projects/search" \
#   -H "Content-Type: application/json" \
#   -d '{
#     "criteria": {
#       "include_active_projects": false
#     },
#     "offset": 500,
#     "limit": 500
#   }' | jq '.results'

# === Example 8: Extract specific fields only ===
echo -e "\n\nExample 8: Extract specific fields (subset)"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "include_active_projects": false,
      "project_end_date": {
        "from_date": "2026-01-01"
      }
    },
    "include_fields": [
      "project_num",
      "project_start_date",
      "project_end_date",
      "is_active",
      "award_amount",
      "org_name",
      "project_title"
    ],
    "offset": 0,
    "limit": 10
  }' | jq '.results[0]'

# === Example 9: Track grant renewals and amendments ===
echo -e "\n\nExample 9: Find all support years for a grant (renewals/amendments)"
# Use core project number to link all versions
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "project_nums": ["5R01AI178795*"]
    },
    "offset": 0,
    "limit": 50
  }' | jq '.results[] | {project_num, support_year: .project_num_split.support_year, is_active, award_amount}'

# === Example 10: Publications linked to grants ===
echo -e "\n\nExample 10: Find publications linked to a specific project"
curl -s -X POST "$API_BASE/publications/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "core_project_nums": ["R01AI178795"]
    },
    "offset": 0,
    "limit": 50
  }' | jq '.meta'

# ============================================================================
# REFERENCE: Field Descriptions
# ============================================================================
# is_active: boolean - Current status (true=active, false=inactive)
# project_end_date: ISO 8601 timestamp - End of award period
# project_start_date: ISO 8601 timestamp - Start of award period
# award_notice_date: ISO 8601 timestamp - Official award notification date
# budget_start, budget_end: Current budget period dates
# date_added: When added to Reporter database
# award_amount: Total cost of award
# direct_cost_amt, indirect_cost_amt: Cost breakdown
# project_num: Full project number (e.g., 5R01AI178795-11)
# core_project_num: Base project number (e.g., R01AI178795)
# activity_code: Award type (R01, R35, F32, etc.)
# fiscal_year: FY of the award
# org_name: Institution name
# project_title: Grant title
# principal_investigators: Array of PI objects with names and profile IDs
# program_officers: Array of PO objects
# agencies: Which NIH IC is administering/funding

# ============================================================================
# RATE LIMITING NOTES
# ============================================================================
# - Maximum 1 request per second recommended
# - Large jobs: Schedule for weekends or 9PM-5AM EST
# - Response includes rate limit headers:
#   X-Rate-Limit-Limit: 1m
#   X-Rate-Limit-Remaining: (count)
#   X-Rate-Limit-Reset: (timestamp)
# - Exceeding limits may result in IP address blocking

# ============================================================================
# USEFUL QUERIES FOR FORENSIC ANALYSIS
# ============================================================================

# Query 1: Find all projects that became inactive in the past 30 days
echo -e "\n\nQuery 1: Newly inactive projects (last 30 days)"
THIRTY_DAYS_AGO=$(date -d "30 days ago" +%Y-%m-%d)
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d "{
    \"criteria\": {
      \"include_active_projects\": false,
      \"date_added\": {
        \"from_date\": \"$THIRTY_DAYS_AGO\"
      }
    },
    \"offset\": 0,
    \"limit\": 500
  }" | jq '.meta.total'

# Query 2: Monitor specific grant for status changes
# Save results and compare over time
echo -e "\n\nQuery 2: Monitor specific grant (example)"
curl -s -X POST "$API_BASE/projects/search" \
  -H "Content-Type: application/json" \
  -d '{
    "criteria": {
      "project_nums": ["5R01AI178795-11"]
    }
  }' | jq '.results[0] | {
    project_num,
    is_active,
    project_end_date,
    award_amount,
    agency: .agency_ic_admin.name
  }'

# Query 3: Bulk export all inactive projects from specific fiscal years
# (Combine multiple requests with different offsets)
echo -e "\n\nQuery 3: Setup for bulk export (would require looping with offset)"
echo "# To export all inactive 2024-2026, loop with offset increments of 500"
echo "# offset: 0, 500, 1000, 1500, ... up to 14999"
