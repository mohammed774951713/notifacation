# awsamNotifacation bootstrap guide

The repository includes a helper script that can rebuild the Laravel-based
`awsamNotifacation` notification backend with all supporting services,
custom models, queue jobs, and console commands described in the original
setup instructions.

## Usage

```bash
./scripts/bootstrap_awsam_notification.sh
```

The script provisions the application within `./mohammed774951713/notifacation/awsamNotifacation`
by default. Override `BASE_PARENT_DIR` or `GITHUB_URL` if you need to clone or
provision the project elsewhere. The automation installs dependencies with
Composer, publishes migrations, enables queue tables, and schedules the
campaign generation commands so that the environment is ready immediately
after the script finishes.

> **Note:** Composer, PHP, and the Laravel installer must be available in the
> environment where you execute the script. Review the script for more details
> about additional environment variables such as `FCM_SERVER_KEY`.
