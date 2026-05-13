<?php
define('CLI_SCRIPT', true);

$moodleDir = getenv('MOODLE_DIR') ?: '/opt/bitnami/moodle';
require_once($moodleDir . '/config.php');
require_once($CFG->dirroot . '/user/lib.php');
require_once($CFG->dirroot . '/course/lib.php');
require_once($CFG->dirroot . '/course/modlib.php');
require_once($CFG->dirroot . '/enrol/locallib.php');
require_once($CFG->libdir . '/clilib.php');

global $CFG, $DB;

set_config('extendedusernamechars', 1);

function esi_user($username, $firstname, $lastname, $email, $password) {
    global $CFG, $DB;

    $user = $DB->get_record('user', ['username' => $username, 'deleted' => 0]);
    if (!$user) {
        $record = (object)[
            'auth' => 'manual',
            'confirmed' => 1,
            'mnethostid' => $CFG->mnet_localhost_id,
            'username' => $username,
            'firstname' => $firstname,
            'lastname' => $lastname,
            'email' => $email,
            'city' => 'Oued Smar',
            'country' => 'DZ',
            'timezone' => 'Africa/Algiers',
            'lang' => 'en',
            'timecreated' => time(),
            'timemodified' => time(),
        ];
        $userid = user_create_user($record, false, false);
        $user = $DB->get_record('user', ['id' => $userid], '*', MUST_EXIST);
    }

    $user->firstname = $firstname;
    $user->lastname = $lastname;
    $user->email = $email;
    $user->timemodified = time();
    user_update_user($user, false, false);
    update_internal_user_password($user, $password);
    return $DB->get_record('user', ['username' => $username, 'deleted' => 0], '*', MUST_EXIST);
}

function esi_course() {
    global $DB;

    $course = $DB->get_record('course', ['shortname' => 'TP-NAC-VPN']);
    if ($course) {
        return $course;
    }

    $category = core_course_category::get_default();
    $record = (object)[
        'fullname' => 'TP - NAC, VPN and Moodle Access',
        'shortname' => 'TP-NAC-VPN',
        'category' => $category->id,
        'summary' => '<p>Practical work for campus access, VPN enrollment, and Moodle publication.</p>',
        'summaryformat' => FORMAT_HTML,
        'format' => 'topics',
        'visible' => 1,
        'numsections' => 4,
        'startdate' => time(),
    ];

    return create_course($record);
}

function esi_enrol($course, $user, $roleShortname) {
    global $DB;

    $role = $DB->get_record('role', ['shortname' => $roleShortname], '*', MUST_EXIST);
    $manual = enrol_get_plugin('manual');
    if (!$manual) {
        throw new moodle_exception('Manual enrolment plugin missing');
    }

    $instance = null;
    foreach (enrol_get_instances($course->id, true) as $candidate) {
        if ($candidate->enrol === 'manual') {
            $instance = $candidate;
            break;
        }
    }

    if (!$instance) {
        $instanceid = $manual->add_instance($course, ['status' => ENROL_INSTANCE_ENABLED]);
        $instance = $DB->get_record('enrol', ['id' => $instanceid], '*', MUST_EXIST);
    }

    if (!$DB->record_exists('user_enrolments', ['enrolid' => $instance->id, 'userid' => $user->id])) {
        $manual->enrol_user($instance, $user->id, $role->id, 0, 0, ENROL_USER_ACTIVE);
    } else {
        $manual->update_user_enrol($instance, $user->id, ENROL_USER_ACTIVE);
        role_assign($role->id, $user->id, context_course::instance($course->id));
    }
}

function esi_page($course) {
    global $DB;

    $name = 'TP1 - Captive portal and VPN evidence';
    if ($DB->record_exists('page', ['course' => $course->id, 'name' => $name])) {
        return;
    }

    if (function_exists('course_create_sections_if_missing')) {
        course_create_sections_if_missing($course, [0, 1]);
    }

    $module = $DB->get_record('modules', ['name' => 'page'], '*', MUST_EXIST);
    $page = (object)[
        'course' => $course->id,
        'module' => $module->id,
        'modulename' => 'page',
        'section' => 1,
        'visible' => 1,
        'visibleoncoursepage' => 1,
        'cmidnumber' => 'tp-nac-vpn-01',
        'name' => $name,
        'intro' => '<p>Read the brief, authenticate through NAC, enroll VPN, and capture proof of access.</p>',
        'introformat' => FORMAT_HTML,
        'content' => '<h3>Objectives</h3><ol><li>Log in to the ESI NAC portal.</li><li>Reach Moodle through moodle.esi.dz.</li><li>Enroll a WireGuard peer through the ESI VPN platform.</li><li>Submit screenshots and command output.</li></ol>',
        'contentformat' => FORMAT_HTML,
        'display' => 5,
        'printheading' => 1,
        'printintro' => 1,
    ];

    add_moduleinfo($page, $course);
}

$professor = esi_user('nora.benali@esi.dz', 'Nora', 'Benali', 'nora.benali@esi.dz', 'NoraTPs#2026');
$students = [
    esi_user('amine.kadri@esi.dz', 'Amine', 'Kadri', 'amine.kadri@esi.dz', 'AmineLab#2026'),
    esi_user('selma.bouaziz@esi.dz', 'Selma', 'Bouaziz', 'selma.bouaziz@esi.dz', 'SelmaLms#2026'),
    esi_user('ilyes.rahmani@esi.dz', 'Ilyes', 'Rahmani', 'ilyes.rahmani@esi.dz', 'IlyesVpn#2026'),
];

$course = esi_course();
esi_enrol($course, $professor, 'editingteacher');
foreach ($students as $student) {
    esi_enrol($course, $student, 'student');
}
esi_page($course);

cli_writeln('ESI Moodle demo ready: moodle.esi.dz course TP-NAC-VPN seeded.');
