package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal(usage)
	}
	mode := os.Args[1]
	cfg, err := loadConfig(mode == "api" || mode == "token" || mode == "rotate-token")
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, err := openDatabase(ctx, cfg)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	switch mode {
	case "api":
		cfg.peerLookup = databasePeerLookup(db)
		cfg.studentState = databaseStudentState(db)
		log.Fatal(serveAPI(cfg, db))
	case "worker":
		log.Fatal(runWorker(cfg, db))
	case "token":
		if len(os.Args) != 3 || !studentIDPattern.MatchString(os.Args[2]) {
			log.Fatal("usage: memento token STUDENT_ID")
		}
		state, err := studentTokenState(context.Background(), db, os.Args[2])
		if err != nil {
			log.Fatal(err)
		}
		fmt.Println(tokenForVersion(cfg.secret, os.Args[2], state.version))
	case "student":
		err = runStudentCommand(context.Background(), db, os.Args[2:])
	case "reset-activation":
		err = runResetActivationCommand(context.Background(), db, os.Args[2:])
	case "regrade":
		err = runRegradeCommand(context.Background(), db, os.Args[2:])
	case "peer":
		err = runPeerCommand(context.Background(), db, os.Args[2:])
	case "peers":
		err = runPeersCommand(context.Background(), db, os.Args[2:], os.Stdin)
	case "rotate-token":
		err = runRotateTokenCommand(context.Background(), db, cfg.secret, os.Args[2:])
	case "disable":
		err = runDisabledCommand(context.Background(), db, os.Args[2:], true)
	case "enable":
		err = runDisabledCommand(context.Background(), db, os.Args[2:], false)
	default:
		log.Fatal(usage)
	}
	if err != nil {
		log.Fatal(err)
	}
}
