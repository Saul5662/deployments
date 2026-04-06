---
description: Use when deciding what console command to run for a given task, and when to inspect logs instead of re-running commands.
---

- Avoid re-running long running commands merely to grep the output. Instead, save the output to a variable and grep that variable when possible. 
  - Note that the testing scripts already save the output of test runs to log files, and the ouput describes where to find those logs. Use the logs for grepping test results instead of re-running tests **unless** there are changes that would affect test results.