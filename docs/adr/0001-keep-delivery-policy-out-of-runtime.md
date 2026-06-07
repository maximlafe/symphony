# Keep delivery policy out of the runtime

Symphony Runtime owns orchestration: it reads eligible Issues, prepares Workspaces, launches Coding Agents, tracks retries and recovery, and exposes operator visibility. Delivery policy such as tracker comments, PR updates, validation expectations, and Handoff rules belongs in the Target Repository's Workflow Contract and agent tooling, because those rules vary by repository and should be versioned with the repository they govern rather than embedded as hidden runtime business logic.
