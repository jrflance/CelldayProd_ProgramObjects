--liquibase formatted sql

--changeset Nicolas Griesdorn c80eeec2 stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-06-11
				:
	Description	: SP used in CRM to add AR accounts to Alphacomm Account Mapping table
				:
	NG20240618  : Hot Fix issued for ISNULL(AccountID) mistake
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Alphacomm_Mapping_Insert_Update]
    (
        @SessionID INT
        , @Option INT
        , @AccountID VARCHAR(MAX)
        , @AlphacommCustomerID VARCHAR(20)
    )
AS
BEGIN TRY
    ----Error Handling (Global)---------------------------------------------------------------------------------------------------------------
    IF ISNULL(@SessionID, 0) <> 2
        RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

    IF ISNULL(@AccountID, '') = '' --NG20240618
        RAISERROR ('The AccountID column cannot be left blank, please enter an AccountID and try again.', 12, 1);

    IF ISNULL(@AlphacommCustomerID, '') = ''
        RAISERROR ('The AlphacommCustomerID column cannot be left blank, please enter an AccountID and try again.', 14, 1);

    -------------------------------------------------------------------------------------------------------------------------------------------

    IF OBJECT_ID('tempdb..#Account') IS NOT NULL
        BEGIN
            DROP TABLE #Account;
        END;

    CREATE TABLE #Account (Account_ID INT)
    INSERT INTO #Account (Account_ID)
    SELECT RESULT
    FROM [dbo].[FnGetStringInTable](@AccountID, ',')

    IF NOT EXISTS (SELECT a.Account_ID FROM dbo.Account AS a JOIN #Account AS ac ON ac.Account_ID = a.Account_ID)
        RAISERROR ('The Account ID entered currently does not exist in our system, please check the Account ID and try again.', 14, 1);
    ------View----------------------------------------------------------------------------------------------------------------------------------

    IF @Option = 0 -- View ESN or SIM
        BEGIN

            SELECT ac.*, aam.AlphacommCustomerId
            FROM #Account AS ac
            JOIN Account.tblAlphacommAccountMapping AS aam ON aam.AccountId = ac.Account_ID

        END;
    ------Update--------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 1 -- Update ESN or SIM
        BEGIN
            MERGE Account.tblAlphacommAccountMapping AS aam
            USING #Account AS ac
                ON aam.AccountId = ac.Account_ID
            WHEN MATCHED
                THEN UPDATE SET aam.AlphacommCustomerId = @AlphacommCustomerID
            WHEN NOT MATCHED
                THEN INSERT
                    (AccountId, AlphacommCustomerId)
                VALUES (ac.Account_ID, @AlphacommCustomerID);


            SELECT ac.*, aam.AlphacommCustomerId
            FROM #Account AS ac
            JOIN Account.tblAlphacommAccountMapping AS aam ON aam.AccountId = ac.Account_ID

        END;
    --------Insert--------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 2
        BEGIN
            IF EXISTS (SELECT aam.AccountId FROM Account.tblAlphacommAccountMapping AS aam JOIN #Account AS ac ON aam.AccountId = ac.Account_ID)
                RAISERROR ('One or more of the VP Product IDs entered already exists in this table, please use the update option to complete this request.', 14, 1); -- noqa: LT05

            IF NOT EXISTS (SELECT a.Account_ID FROM dbo.Account AS a JOIN #Account AS ac ON ac.Account_ID = a.Account_ID)
                RAISERROR ('The Account ID entered currently does not exist in our system, please check the Account ID and try again.', 14, 1);

            MERGE Account.tblAlphacommAccountMapping AS aam
            USING #Account AS ac
                ON aam.AccountId = ac.Account_ID
            WHEN NOT MATCHED
                THEN INSERT
                    (AccountId, AlphacommCustomerId)
                VALUES (ac.Account_ID, @AlphacommCustomerID);


            SELECT ac.*, aam.AlphacommCustomerId
            FROM #Account AS ac
            JOIN Account.tblAlphacommAccountMapping AS aam ON aam.AccountId = ac.Account_ID
        END;

END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
