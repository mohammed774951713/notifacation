#!/usr/bin/env bash
set -euo pipefail

# =========[ إعداد المسارات والمتغيرات ]=========
BASE_PARENT_DIR="${BASE_PARENT_DIR:-$PWD}"  # اسمح بتجاوز المسار من الخارج
ORG_DIR="mohammed774951713"
REPO_DIR="notifacation"
APP_NAME="awsamNotifacation"
APP_PATH="${BASE_PARENT_DIR}/${ORG_DIR}/${REPO_DIR}/${APP_NAME}"
GITHUB_URL="${GITHUB_URL:-https://github.com/mohammed774951713/notifacation.git}"

echo ">> Base: ${BASE_PARENT_DIR}"
echo ">> Target: ${APP_PATH}"
mkdir -p "${BASE_PARENT_DIR}/${ORG_DIR}/${REPO_DIR}"

# =========[ إنشاء مشروع Laravel ]=========
cd "${BASE_PARENT_DIR}/${ORG_DIR}/${REPO_DIR}"
if [ ! -d "${APP_NAME}" ]; then
  composer create-project laravel/laravel "${APP_NAME}"
fi
cd "${APP_NAME}"

php artisan key:generate

# =========[ .env وإعدادات أولية ]=========
# لا نغطي كل مفاتيح DB هنا—عدّلها لاحقًا حسب بيئتك
if ! grep -q "FCM_SERVER_KEY" .env; then
cat >> .env <<'ENVEOF'

# =================== Custom Notification Settings ===================
APP_TIMEZONE=UTC

# FCM
FCM_SERVER_KEY=   # ضع مفتاح FCM Server Key هنا
FCM_SENDER_ID=

# Quiet hours (0..23)
QUIET_START_HOUR=0
QUIET_END_HOUR=1

# Generation horizon in minutes
SCHEDULE_HORIZON_MINUTES=120

# Queue driver (database أو redis)
QUEUE_CONNECTION=database
ENVEOF
fi

# =========[ تعديل config/services.php لإضافة fcm ]=========
php -r '
$f="config/services.php";
$c=file_get_contents($f);
if(strpos($c,'\'fcm\'')===false){
  $c=preg_replace("/return\\s*\[/","return [\n    '\'fcm\'' => [\n        '\'server_key\'' => env('\'FCM_SERVER_KEY\'', '\'\''),\n    ],\n",$c,1);
  file_put_contents($f,$c);
}
'

# =========[ مسارات للكود المخصص ]=========
mkdir -p app/Services app/Support app/Http/Controllers/Api app/Console/Commands app/Jobs app/Models database/migrations

# =========[ موديلات ]=========
cat > app/Models/Campaign.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class Campaign extends Model {
    protected $fillable = [
        'title','body','deep_link','start_hour','end_hour',
        'max_per_week','min_days_since_install','cooldown_days','active'
    ];
    protected $casts = ['active' => 'boolean'];
}
PHP

cat > app/Models/Device.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class Device extends Model {
    protected $fillable = [
        'user_id','platform','fcm_token','timezone','installed_at','meta','last_notified_at'
    ];
    protected $casts = [
        'installed_at' => 'datetime',
        'last_notified_at' => 'datetime',
        'meta' => 'array',
    ];
}
PHP

cat > app/Models/ScheduledNotification.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class ScheduledNotification extends Model {
    protected $fillable = ['campaign_id','device_id','fire_at','status','payload','sent_at','failure_reason'];
    protected $casts = [
        'fire_at' => 'datetime',
        'sent_at' => 'datetime',
        'payload' => 'array',
    ];
    public function campaign(): BelongsTo { return $this->belongsTo(Campaign::class); }
    public function device(): BelongsTo { return $this->belongsTo(Device::class); }
}
PHP

cat > app/Models/CampaignLog.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class CampaignLog extends Model {
    protected $fillable = ['campaign_id','device_id','delivered_at'];
    protected $casts = ['delivered_at' => 'datetime'];
}
PHP

# =========[ TimeUtils ]=========
cat > app/Support/TimeUtils.php <<'PHP'
<?php
namespace App\Support;
use Carbon\Carbon;
use Carbon\CarbonInterface;

class TimeUtils {
    public static function inQuietHours(CarbonInterface $ts): bool {
        $start = (int) env('QUIET_START_HOUR', 0);
        $end   = (int) env('QUIET_END_HOUR', 1);
        $h = (int) $ts->format('G');
        if ($start < $end) return $h >= $start && $h < $end;
        return $h >= $start || $h < $end;
    }

    public static function weekId(CarbonInterface $ts): string {
        return $ts->format('o-\\WW');
    }

    public static function nextAllowedFireAt(Carbon $nowLocal, int $startHour, int $endHour): Carbon {
        $fire = $nowLocal->copy()->addMinute();
        if ($fire->hour < $startHour) {
            $fire->setTime($startHour, 0);
        } elseif ($fire->hour >= $endHour) {
            $fire->addDay()->setTime($startHour, 0);
        }
        if (self::inQuietHours($fire)) {
            $end = (int) env('QUIET_END_HOUR', 1);
            $fire->setTime($end, 0);
            if ($fire->hour < $startHour) $fire->setTime($startHour, 0);
            if ($fire->hour >= $endHour) $fire->addDay()->setTime($startHour, 0);
        }
        return $fire;
    }
}
PHP

# =========[ FCM Service ]=========
cat > app/Services/FcmService.php <<'PHP'
<?php
namespace App\Services;
use Illuminate\Support\Facades\Http;

class FcmService {
    protected string $serverKey;
    public function __construct() {
        $this->serverKey = (string) config('services.fcm.server_key');
    }
    public function sendToToken(string $token, array $data): array {
        $payload = [
            'to' => $token,
            'notification' => [
                'title' => $data['title'] ?? '',
                'body'  => $data['body'] ?? '',
            ],
            'data' => $data,
            'android' => [ 'priority' => 'high' ],
            'apns' => [
                'headers' => ['apns-priority' => '10'],
                'payload' => ['aps' => ['content-available' => 1]],
            ],
        ];
        $resp = Http::withToken($this->serverKey)
            ->acceptJson()
            ->post('https://fcm.googleapis.com/fcm/send', $payload);

        return [
            'ok' => $resp->successful(),
            'status' => $resp->status(),
            'body' => $resp->json(),
        ];
    }
}
PHP

# =========[ Controllers + Routes ]=========
mkdir -p app/Http/Controllers/Api

cat > app/Http/Controllers/Api/DeviceController.php <<'PHP'
<?php
namespace App\Http\Controllers\Api;
use App\Http\Controllers\Controller;
use App\Models\Device;
use Carbon\Carbon;
use Illuminate\Http\Request;

class DeviceController extends Controller {
    public function register(Request $r) {
        $data = $r->validate([
            'fcm_token' => 'required|string',
            'platform'  => 'nullable|string',
            'timezone'  => 'nullable|string',
            'installed_at' => 'nullable|date',
            'user_id'   => 'nullable|integer',
            'meta'      => 'nullable|array',
        ]);

        $device = Device::updateOrCreate(
            ['fcm_token' => $data['fcm_token']],
            [
                'user_id' => $data['user_id'] ?? null,
                'platform'=> $data['platform'] ?? null,
                'timezone'=> $data['timezone'] ?? 'UTC',
                'installed_at' => isset($data['installed_at']) ? Carbon::parse($data['installed_at']) : now(),
                'meta' => $data['meta'] ?? null,
            ]
        );

        return response()->json(['ok' => true, 'device_id' => $device->id]);
    }
}
PHP

cat > app/Http/Controllers/Api/CampaignController.php <<'PHP'
<?php
namespace App\Http\Controllers\Api;
use App\Http\Controllers\Controller;
use App\Models\Campaign;

class CampaignController extends Controller {
    public function index() {
        return Campaign::query()->where('active', true)->get();
    }
}
PHP

# routes/api.php append
if ! grep -q "devices/register" routes/api.php; then
cat >> routes/api.php <<'PHP'

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\Api\DeviceController;
use App\Http\Controllers\Api\CampaignController;

Route::post('/devices/register', [DeviceController::class, 'register']);
Route::get('/campaigns', [CampaignController::class, 'index']);
PHP
fi

# =========[ Console Commands ]=========
cat > app/Console/Commands/GenerateCampaignSchedules.php <<'PHP'
<?php
namespace App\Console\Commands;

use App\Models\Campaign;
use App\Models\CampaignLog;
use App\Models\Device;
use App\Models\ScheduledNotification;
use App\Support\TimeUtils;
use Carbon\Carbon;
use Illuminate\Console\Command;

class GenerateCampaignSchedules extends Command {
    protected $signature = 'campaigns:generate-schedules';
    protected $description = 'Generate scheduled notifications for active campaigns within horizon';

    public function handle(): int {
        $horizonMin = (int) env('SCHEDULE_HORIZON_MINUTES', 120);
        $nowUtc = Carbon::now('UTC');

        $campaigns = Campaign::query()->where('active', true)->get();
        $devices   = Device::query()->get();

        foreach ($devices as $device) {
            $tz = $device->timezone ?: 'UTC';
            $nowLocal = $nowUtc->copy()->setTimezone($tz);

            foreach ($campaigns as $c) {
                if (TimeUtils::inQuietHours($nowLocal)) continue;
                if (!($nowLocal->hour >= $c->start_hour && $nowLocal->hour < $c->end_hour)) continue;

                if ($device->installed_at) {
                    $days = $nowLocal->diffInDays($device->installed_at->copy()->setTimezone($tz));
                    if ($days < $c->min_days_since_install) continue;
                }

                $lastLog = CampaignLog::query()
                    ->where('campaign_id', $c->id)->where('device_id', $device->id)
                    ->orderByDesc('delivered_at')->first();
                if ($lastLog && $nowLocal->diffInDays($lastLog->delivered_at->copy()->setTimezone($tz)) < $c->cooldown_days) {
                    continue;
                }

                $startOfWeek = $nowLocal->copy()->startOfWeek();
                $endOfWeek   = $nowLocal->copy()->endOfWeek();
                $countThisWeek = CampaignLog::query()
                    ->where('campaign_id', $c->id)->where('device_id', $device->id)
                    ->whereBetween('delivered_at', [$startOfWeek->copy()->utc(), $endOfWeek->copy()->utc()])
                    ->count();
                if ($countThisWeek >= $c->max_per_week) continue;

                $fireAtLocal = TimeUtils::nextAllowedFireAt($nowLocal, $c->start_hour, $c->end_hour);
                if ($fireAtLocal->diffInMinutes($nowLocal) > $horizonMin) continue;

                $fireAtUtc = $fireAtLocal->copy()->utc();
                $payload = [
                    'title' => $c->title,
                    'body'  => $c->body,
                    'deepLink' => $c->deep_link,
                    'campaignId' => $c->id,
                ];

                ScheduledNotification::firstOrCreate(
                    ['campaign_id' => $c->id, 'device_id' => $device->id, 'fire_at' => $fireAtUtc],
                    ['status' => 'pending', 'payload' => $payload]
                );
            }
        }

        $this->info('Schedules generation done.');
        return self::SUCCESS;
    }
}
PHP

cat > app/Console/Commands/DispatchDueNotifications.php <<'PHP'
<?php
namespace App\Console\Commands;

use App\Jobs\SendScheduledNotification;
use App\Models\ScheduledNotification;
use Carbon\Carbon;
use Illuminate\Console\Command;

class DispatchDueNotifications extends Command {
    protected $signature = 'campaigns:dispatch-due';
    protected $description = 'Dispatch jobs for scheduled notifications that are due';

    public function handle(): int {
        $nowUtc = Carbon::now('UTC');

        $due = ScheduledNotification::query()
            ->where('status', 'pending')
            ->where('fire_at', '<=', $nowUtc)
            ->limit(500)
            ->get();

        foreach ($due as $s) {
            dispatch(new SendScheduledNotification($s))->onQueue('notifications');
        }

        $this->info("Dispatched {$due->count()} notifications.");
        return self::SUCCESS;
    }
}
PHP

# =========[ Job: SendScheduledNotification ]=========
cat > app/Jobs/SendScheduledNotification.php <<'PHP'
<?php
namespace App\Jobs;

use App\Models\CampaignLog;
use App\Models\ScheduledNotification;
use App\Services\FcmService;
use Carbon\Carbon;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;

class SendScheduledNotification implements ShouldQueue {
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public function __construct(public ScheduledNotification $scheduled) {}

    public function handle(FcmService $fcm): void {
        $s = $this->scheduled->fresh();
        if (!$s || $s->status !== 'pending') return;

        $device  = $s->device;
        $payload = $s->payload ?? [];
        $resp = $fcm->sendToToken($device->fcm_token, $payload);

        if ($resp['ok'] ?? false) {
            $s->update(['status' => 'sent', 'sent_at' => Carbon::now('UTC')]);
            CampaignLog::create([
                'campaign_id' => $s->campaign_id,
                'device_id'   => $s->device_id,
                'delivered_at'=> Carbon::now('UTC'),
            ]);
        } else {
            $s->update([
                'status' => 'failed',
                'failure_reason' => json_encode($resp),
            ]);
        }
    }
}
PHP

# =========[ Kernel: جدولة الأوامر ]=========
php -r '
$f="app/Console/Kernel.php";
$c=file_get_contents($f);
$c=preg_replace("/protected function schedule\\(Schedule \\$schedule\\): void\\s*\{[\\s\\S]*?\}/",
"protected function schedule(Schedule \\$schedule): void {\n    \\$schedule->command(\\App\\Console\\Commands\\GenerateCampaignSchedules::class)->everyFiveMinutes()->withoutOverlapping();\n    \\$schedule->command(\\App\\Console\\Commands\\DispatchDueNotifications::class)->everyMinute()->withoutOverlapping();\n}", $c);
file_put_contents($f,$c);
'

# =========[ Migrations (بتواريخ ديناميكية) ]=========
ts_base="$(date +%Y_%m_%d_%H%M%S)"
# لضمان تميّز الأختام نضيف +1 ثانية لكل ملف
ts1="${ts_base}_000001"
ts2="${ts_base}_000002"
ts3="${ts_base}_000003"
ts4="${ts_base}_000004"

cat > "database/migrations/${ts1}_create_campaigns_table.php" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
  public function up(): void {
    Schema::create('campaigns', function (Blueprint $table) {
      $table->id();
      $table->string('title');
      $table->text('body')->nullable();
      $table->string('deep_link')->default('/');
      $table->unsignedTinyInteger('start_hour')->default(8);
      $table->unsignedTinyInteger('end_hour')->default(22);
      $table->unsignedSmallInteger('max_per_week')->default(3);
      $table->unsignedSmallInteger('min_days_since_install')->default(0);
      $table->unsignedSmallInteger('cooldown_days')->default(1);
      $table->boolean('active')->default(true);
      $table->timestamps();
    });
  }
  public function down(): void { Schema::dropIfExists('campaigns'); }
};
PHP

cat > "database/migrations/${ts2}_create_devices_table.php" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
  public function up(): void {
    Schema::create('devices', function (Blueprint $table) {
      $table->id();
      $table->foreignId('user_id')->nullable()->constrained()->nullOnDelete();
      $table->string('platform', 20)->nullable();
      $table->string('fcm_token')->unique();
      $table->string('timezone')->nullable();
      $table->timestamp('installed_at')->nullable();
      $table->timestamp('last_notified_at')->nullable();
      $table->json('meta')->nullable();
      $table->timestamps();
    });
  }
  public function down(): void { Schema::dropIfExists('devices'); }
};
PHP

cat > "database/migrations/${ts3}_create_scheduled_notifications_table.php" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
  public function up(): void {
    Schema::create('scheduled_notifications', function (Blueprint $table) {
      $table->id();
      $table->foreignId('campaign_id')->constrained()->cascadeOnDelete();
      $table->foreignId('device_id')->constrained()->cascadeOnDelete();
      $table->timestamp('fire_at');
      $table->string('status', 20)->default('pending');
      $table->json('payload')->nullable();
      $table->timestamp('sent_at')->nullable();
      $table->string('failure_reason')->nullable();
      $table->timestamps();

      $table->unique(['campaign_id','device_id','fire_at'], 'uniq_sched_triplet');
      $table->index(['status','fire_at']);
    });
  }
  public function down(): void { Schema::dropIfExists('scheduled_notifications'); }
};
PHP

cat > "database/migrations/${ts4}_create_campaign_logs_table.php" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
  public function up(): void {
    Schema::create('campaign_logs', function (Blueprint $table) {
      $table->id();
      $table->foreignId('campaign_id')->constrained()->cascadeOnDelete();
      $table->foreignId('device_id')->constrained()->cascadeOnDelete();
      $table->timestamp('delivered_at');
      $table->timestamps();
      $table->index(['campaign_id','device_id','delivered_at']);
    });
  }
  public function down(): void { Schema::dropIfExists('campaign_logs'); }
};
PHP

# =========[ Queue tables migration لو اخترت database ]=========
php artisan queue:table || true

# =========[ Composer dump-autoload ]=========
composer dump-autoload -o

# =========[ تشغيل الميجريشنز ]=========
php artisan migrate

# =========[ Git init + remote ]=========
if [ ! -d .git ]; then
  git init
  git add .
  git commit -m "feat: initial awsamNotifacation (notifications backend)"
  git branch -M main
  git remote add origin "${GITHUB_URL}" || true
  # ملاحظة: ادفع فقط إذا الضبط لديك صحيح (توكن/SSH). أزل التعليق للسطر التالي إن أردت الدفع مباشرة.
  # git push -u origin main
fi

echo
echo "✅ DONE. Project path: ${APP_PATH}"
echo "➡️  عدّل .env (DB + FCM_SERVER_KEY) ثم شغّل:"
echo "    php artisan queue:work --queue=notifications --tries=3"
echo "    * * * * * php ${APP_PATH}/artisan schedule:run >> /dev/null 2>&1"
