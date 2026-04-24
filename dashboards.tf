# CloudWatch Dashboard for AWS Service Monitor
# Provides real-time visibility into system health and performance

resource "aws_cloudwatch_dashboard" "service_monitor" {
  dashboard_name = "aws-service-monitor"

  dashboard_body = jsonencode({
    widgets = [
      # Widget 1: Lambda Invocations
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", { stat = "Sum", label = "Invocations" }]
          ]
          period = 3600
          stat   = "Sum"
          region = var.aws_region
          title  = "Lambda Invocations (Daily)"
          yAxis = {
            left = {
              min = 0
            }
          }
        }
        width  = 12
        height = 6
        x      = 0
        y      = 0
      },

      # Widget 2: Lambda Errors
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Errors", { stat = "Sum", label = "Errors" }]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
          title  = "Lambda Errors (5-minute)"
          yAxis = {
            left = {
              min = 0
            }
          }
          alarm_colors = {
            alarm_color  = "#d13212"
            ok_color     = "#2ca02c"
            insufficient_data_color = "#cccccc"
          }
        }
        width  = 12
        height = 6
        x      = 12
        y      = 0
      },

      # Widget 3: Lambda Duration (Average & P99)
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Duration", { stat = "Average", label = "Average Duration" }],
            ["...", { stat = "p99", label = "P99 Duration" }]
          ]
          period = 3600
          stat   = "Average"
          region = var.aws_region
          title  = "Lambda Duration (hourly)"
          yAxis = {
            left = {
              min  = 0
              max  = 300000
              label = "Milliseconds"
            }
          }
        }
        width  = 12
        height = 6
        x      = 0
        y      = 6
      },

      # Widget 4: DynamoDB Consumed Capacity
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", { stat = "Sum", label = "Read Units" }],
            [".", "ConsumedWriteCapacityUnits", { stat = "Sum", label = "Write Units" }]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
          title  = "DynamoDB Consumed Capacity (5-minute)"
          yAxis = {
            left = {
              min = 0
            }
          }
        }
        width  = 12
        height = 6
        x      = 12
        y      = 6
      },

      # Widget 5: DynamoDB User Errors (Throttles)
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/DynamoDB", "UserErrors", { stat = "Sum", label = "Throttles" }]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
          title  = "DynamoDB User Errors (5-minute)"
          yAxis = {
            left = {
              min = 0
            }
          }
          alarm_colors = {
            alarm_color  = "#d13212"
            ok_color     = "#2ca02c"
            insufficient_data_color = "#cccccc"
          }
        }
        width  = 12
        height = 6
        x      = 0
        y      = 12
      },

      # Widget 6: Custom - New Services Detected
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/ServiceMonitor", "NewServicesDetected", { stat = "Sum", label = "New Services" }]
          ]
          period = 3600
          stat   = "Sum"
          region = var.aws_region
          title  = "New Services Detected (Daily)"
          yAxis = {
            left = {
              min = 0
            }
          }
        }
        width  = 12
        height = 6
        x      = 12
        y      = 12
      },

      # Widget 7: Custom - Baseline Integrity Status
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/ServiceMonitor", "BaselineIntegrityStatus", { stat = "Minimum", label = "Integrity OK" }]
          ]
          period = 300
          stat   = "Minimum"
          region = var.aws_region
          title  = "Baseline Integrity Status (5-minute)"
          yAxis = {
            left = {
              min = 0
              max = 1
            }
          }
          alarm_colors = {
            alarm_color  = "#d13212"
            ok_color     = "#2ca02c"
            insufficient_data_color = "#999999"
          }
        }
        width  = 12
        height = 6
        x      = 0
        y      = 18
      },

      # Widget 8: Lambda Logs (Recent Errors)
      {
        type = "log"
        properties = {
          query   = "fields @timestamp, @message | filter @message like /ERROR/ | stats count() by @message | sort count() desc | limit 10"
          region  = var.aws_region
          title   = "Recent Lambda Errors (Last Hour)"
          queryId = "recent-errors"
        }
        width  = 12
        height = 6
        x      = 12
        y      = 18
      },

      # Widget 9: CloudWatch Logs Insights - Execution Timeline
      {
        type = "log"
        properties = {
          query   = "fields @timestamp, @message | filter @message like /Starting AWS service monitor|Processed|No new services/ | sort @timestamp desc | limit 20"
          region  = var.aws_region
          title   = "Execution Timeline (Recent Runs)"
          queryId = "execution-timeline"
        }
        width  = 24
        height = 6
        x      = 0
        y      = 24
      }
    ]
  })
}
