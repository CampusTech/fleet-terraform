moved {
  from = module.fleet_lb
  to   = module.fleet_lb[0]
}

# Fork-only: the module-managed secret grants were a for_each keyed by env var
# name; upstream names them individually.
moved {
  from = google_secret_manager_secret_iam_member.fleet_run_sa_secret_access["FLEET_MYSQL_PASSWORD"]
  to   = google_secret_manager_secret_iam_member.fleet_run_sa_db_secret_access
}

moved {
  from = google_secret_manager_secret_iam_member.fleet_run_sa_secret_access["FLEET_SERVER_PRIVATE_KEY"]
  to   = google_secret_manager_secret_iam_member.fleet_run_sa_private_key_secret_access
}
