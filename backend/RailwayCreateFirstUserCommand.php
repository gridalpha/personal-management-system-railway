<?php

namespace App\Command;

use App\Entity\User;
use App\Services\Security\PasswordHashingService;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Creates the very first account from environment variables.
 *
 * Registration in this app is open to anyone until the first active user exists
 * (App\Action\System\AppAction::registerUser), so on a public URL whoever loads the
 * page first owns the deployment. This runs from the entrypoint before nginx binds
 * the public port, which closes that window instead of narrowing it.
 *
 * It mirrors registerUser's whole side effect rather than restating any DDL, and it
 * is a no-op once an active user exists, so it can never revert an operator's own
 * account or password.
 */
class RailwayCreateFirstUserCommand extends Command
{
    protected static $defaultName = 'railway:create-first-user';
    protected static $defaultDescription = 'Create the first PMS account from PMS_ADMIN_* variables, once.';

    public function __construct(
        private readonly EntityManagerInterface $em,
        private readonly PasswordHashingService $passwordHashingService
    ) {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->setName('railway:create-first-user')
             ->setDescription('Create the first PMS account from PMS_ADMIN_* variables, once.');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $repository = $this->em->getRepository(User::class);

        if (!is_null($repository->findOneActive())) {
            $output->writeln('[first-user] an active user already exists - skipping');

            return Command::SUCCESS;
        }

        $email        = $this->env('PMS_ADMIN_EMAIL');
        $username     = $this->env('PMS_ADMIN_USERNAME');
        $password     = $this->env('PMS_ADMIN_PASSWORD');
        $lockPassword = $this->env('PMS_ADMIN_LOCK_PASSWORD');

        if ($lockPassword === '') {
            $lockPassword = $password;
        }

        if ($email === '' || $username === '' || $password === '') {
            $output->writeln('[first-user] PMS_ADMIN_EMAIL, PMS_ADMIN_USERNAME and PMS_ADMIN_PASSWORD must all be set');

            return Command::FAILURE;
        }

        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            $output->writeln("[first-user] PMS_ADMIN_EMAIL is not a valid e-mail address: {$email}");

            return Command::FAILURE;
        }

        if (!is_null($repository->findOneByEmail($email))) {
            $output->writeln('[first-user] a user with that e-mail already exists - skipping');

            return Command::SUCCESS;
        }

        $user = new User();
        $user->setPassword($this->passwordHashingService->encode($password));
        $user->setLockPassword($this->passwordHashingService->encode($lockPassword));
        $user->setEnabled(true);
        $user->setUsername($username);
        $user->setUsernameCanonical($username);
        $user->setEmail($email);
        $user->setEmailCanonical($email);

        $this->em->persist($user);
        $this->em->flush();

        $output->writeln("[first-user] created the first account for {$email}");

        return Command::SUCCESS;
    }

    private function env(string $key): string
    {
        $value = getenv($key);
        if ($value === false || $value === '') {
            $value = $_ENV[$key] ?? $_SERVER[$key] ?? '';
        }

        return trim((string) $value);
    }
}
