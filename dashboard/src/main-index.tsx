import { start } from './boot-screen.tsx';
import { AppProvider } from './ui/kit.tsx';
import { BusinessApp } from './business/App.tsx';

start((sb) => <AppProvider sb={sb} initial={{ userId: sb.people.chanor.id, context: null }}><BusinessApp /></AppProvider>);
