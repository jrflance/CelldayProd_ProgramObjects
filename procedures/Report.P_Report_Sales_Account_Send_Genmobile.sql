--liquibase formatted sql

--changeset KarinaMasihHudson:71a4e5818ddf42229eb14e507eb8a9ec stripComments:false runOnChange:true splitStatements:false
/* =============================================
      Author : Karina Masih-Hudson
     Created : 2024-05-14
 Description : This report allows the Sales team to override GenMobile status. Leave Notes blank to not update.
             : Based on P_Report_Sales_Account_Send_VZW
			 : Status: --All|-1|
						 Need Review|1|
						 Pending/Submitted to Cricket Waiting Approval|2|
						 Active|3|
						 Closed|4|
						 Denied|5|
						 Swap-Closed|6|
						 Denied by Tcetra|7|
						 Inactive|8|
						 Closed-Fraud|9|
						 Ignore|255|
			 : Action: Show|0|
					   Update|1|
 =============================================*/
CREATE OR ALTER PROCEDURE [Report].[P_Report_Sales_Account_Send_Genmobile]
    (
        @Account VARCHAR(MAX)
        , @GMStoreID VARCHAR(10)
        , @OutletID VARCHAR(15)
        , @status INT
        , @TotalMonthlyAct INT
        , @GMMonthlyAct INT
        , @PrefLanguage NVARCHAR(25)
        , @Notes VARCHAR(MAX)
        , @Action BIT --Show|0|Update|1|
        , @SessionUserID INT
        , @SessionAccountID INT
    )
AS

BEGIN TRY
    --DECLARE
    --@Account VARCHAR(MAX) = '13379,117783'
    --, @GMStoreID VARCHAR(10) = '1111'
    --, @OutletID VARCHAR(15)  = NULL
    --, @status INT = 4
    --, @TotalMonthlyAct INT = 100
    --, @GMMonthlyAct INT = 75
    --, @PrefLanguage NVARCHAR(25) = 'Spanish'
    --, @Notes VARCHAR(MAX) = 'testing'
    --, @Action BIT = 1  --Show|0|Update|1|
    --, @SessionUserID INT = 227824
    --, @SessionAccountID INT = 2

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF ISNULL(@SessionAccountID, 0) <> 2 --Restrict to Account 2
        BEGIN
            SELECT 'This report is highly restricted! Please see your T-Cetra representative if you need access.' AS [Error Message];
            RETURN;
        END;

    IF (ISNULL(@Account, '') = '')
        BEGIN
            SELECT 'Must enter Account IDs' AS [Error Message];
            RETURN;
        END;

    IF ISNULL(@SessionUserID, 0) NOT IN (264154, 209361, 9915, 10844, 159497, 225057, 227824)
    --Users:dwethey,twalberg,jlippoli,tbraskett,aalshaar,khudson
        BEGIN
            SELECT 'Your User ID does not have access to this report. Please see your manager if you wish to request access.' AS [Error Message];
            RETURN;
        END;



    DECLARE @Username NVARCHAR(50)
    SET @UserName = (SELECT UserName FROM dbo.Users WHERE User_ID = ISNULL(@SessionUserID, -1) AND Account_ID = 2)


    IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfAccounts;
        END;


    CREATE TABLE #ListOfAccounts (AccountID INT);
    INSERT INTO #ListOfAccounts
    (
        AccountID
    )
    SELECT ID
    FROM dbo.fnSplitter(@Account);


    IF
        EXISTS
        (
            SELECT 1
            FROM #ListOfAccounts AS la
            WHERE
                NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.Account AS a
                    WHERE
                        a.Account_ID = la.AccountID
                        AND ISNULL(a.AccountType_ID, 0) IN (2, 11)
                )
        )
        BEGIN
            SELECT 'Invalid Account Entered' AS [Error Message];
            RETURN;
        END;

    ----------------------------------------------------------------
    IF (@Action = 1)
        BEGIN

            IF
                NOT EXISTS
                (
                    SELECT tas.StatusID FROM [CarrierSetup].[tblAccountStoreStatus] AS tas WHERE tas.StatusID = ISNULL(@status, 0)
                )
                BEGIN
                    SELECT 'Invalid Status Entered' AS [Error Message];
                    RETURN;
                END;

            IF
                @status = 1			--'Need Review'
                AND @Action = 1
                AND (
                    ISNULL(@TotalMonthlyAct, 0) = 0 OR ISNULL(@GMMonthlyAct, 0) = 0 OR ISNULL(@PrefLanguage, '') = ''
                )
                BEGIN
                    SELECT 'Must enter Total Monthly Activation, Gen mobile monthly activation forecast, Preferred language.' AS [Error Message]
                    RETURN;
                END;


            IF (
                @status = 1
                AND EXISTS
                (
                    SELECT 1
                    FROM #ListOfAccounts AS la
                    JOIN dbo.Account AS a
                        ON la.AccountID = a.Account_ID
                    LEFT JOIN dbo.Customers AS c
                        ON c.Customer_ID = a.Contact_ID
                    WHERE (
                        ISNULL(a.Account_Name, '') = ''
                        OR ISNULL(c.Address1, '') = ''
                        OR ISNULL(c.City, '') = ''
                        OR ISNULL(c.State, '') = ''
                        OR ISNULL(c.Zip, '') = ''
                        OR ISNULL(c.Phone, '') = ''
                        OR ISNULL(c.Email, '') = ''
                        OR ISNULL(c.FirstName, '') = ''
                        OR ISNULL(c.LastName, '') = ''
                    )
                )
            )
                BEGIN
                    SELECT
                        CAST(la.AccountID AS VARCHAR(MAX)) + ' Is Missing Data' AS [Error],
                        a.Account_Name,
                        c.Address1,
                        c.City,
                        c.State,
                        c.Zip,
                        c.Phone,
                        c.Email,
                        c.FirstName,
                        c.LastName
                    FROM #ListOfAccounts AS la
                    JOIN dbo.Account AS a
                        ON la.AccountID = a.Account_ID
                    LEFT JOIN dbo.Customers AS c
                        ON c.Customer_ID = a.Contact_ID
                    WHERE (
                        ISNULL(a.Account_Name, '') = ''
                        OR ISNULL(c.Address1, '') = ''
                        OR ISNULL(c.City, '') = ''
                        OR ISNULL(c.State, '') = ''
                        OR ISNULL(c.Zip, '') = ''
                        OR ISNULL(c.Phone, '') = ''
                        OR ISNULL(c.Email, '') = ''
                        OR ISNULL(c.FirstName, '') = ''
                        OR ISNULL(c.LastName, '') = ''
                    );
                    RETURN;
                END;

            INSERT INTO CarrierSetup.tblGenmobileAccountStore
            (
                AccountId, GMStoreId, StatusID, OutletID
                , Comments, TotalMonthlyActivation, GMMonthlyActivationForecast, PrefLang
                , Update_Tms
            )
            SELECT
                la.AccountID,
                @GMStoreID AS GMStoreID,
                @status AS StatusID,
                @OutletID AS OutletID,
                ISNULL(@Notes, '') AS Comments,
                @TotalMonthlyAct AS TotalMonthlyActivation,
                @GMMonthlyAct AS GMMonthlyActivationForecast,
                @PrefLanguage AS PrefLang,
                GETDATE() AS UpdateDate
            FROM #ListOfAccounts AS la
            WHERE
                NOT EXISTS
                (
                    SELECT 1
                    FROM CarrierSetup.tblGenmobileAccountStore AS gas
                    WHERE la.AccountID = gas.AccountId
                );


            IF (ISNULL(@Notes, '') <> '')
                BEGIN
                    UPDATE gas
                    SET gas.Comments = @Notes
                    FROM CarrierSetup.tblGenmobileAccountStore AS gas
                    JOIN #ListOfAccounts AS la
                        ON la.AccountID = gas.AccountId;
                END;


            IF @status = 1
                BEGIN
                    UPDATE gas
                    SET
                        gas.TotalMonthlyActivation = @TotalMonthlyAct,
                        gas.GMStoreId = @GMStoreID,
                        gas.GMMonthlyActivationForecast = @GMMonthlyAct,
                        gas.PrefLang = @PrefLanguage
                    FROM CarrierSetup.tblGenmobileAccountStore AS gas
                    JOIN #ListOfAccounts AS la
                        ON la.AccountID = gas.AccountId
                END


            IF (@status = 2)			--Pending/Submitted to carrier Waiting Approval
                UPDATE gas
                SET
                    gas.StatusID = @status,
                    gas.Update_Tms = GETDATE()
                OUTPUT
                    Inserted.AccountId,
                    Deleted.StatusID,
                    Inserted.StatusID
                INTO
                    Logs.tblCricketAccountStoreLogs
                    (
                        AccountID,
                        OldStatusID,
                        NewStatusID
                    )
                FROM CarrierSetup.tblGenmobileAccountStore AS gas
                JOIN #ListOfAccounts AS la
                    ON la.AccountID = gas.AccountId
                WHERE gas.StatusID <> @status;

            IF (@status = 3)
                IF
                    @status = 3
                    AND @Action = 1
                    AND (
                        ISNULL(@GMStoreID, 0) = 0
                    )
                    BEGIN
                        SELECT 'Gen mobile Store ID must be entered' AS [Error Message]
                        RETURN;
                    END;


            BEGIN
            --Update tblGMAccountStore with active, if exists update log
                UPDATE gas
                SET
                    gas.StatusID = @status,
                    gas.GMStoreId = @GMStoreID,
                    gas.OutletID = CASE
                        WHEN ISNULL(@OutletID, '') = ''
                            THEN (
                                SELECT gas.OutletID
                                FROM CarrierSetup.tblGenmobileAccountStore AS gas
                                WHERE gas.AccountId = la.accountid
                            )
                        ELSE @OutletID
                    END,
                    gas.Update_Tms = GETDATE()
                OUTPUT
                    Inserted.AccountId,
                    270 AS CarrierID,
                    Deleted.StatusID,
                    Inserted.StatusID
                INTO
                    Logs.tblAccountStoreLogs
                    (
                        AccountID,
                        CarrierID, --Gen mobile
                        OldStatusID,
                        NewStatusID
                    )
                FROM CarrierSetup.tblGenmobileAccountStore AS gas
                JOIN #ListOfAccounts AS la
                    ON la.AccountID = gas.AccountId


                ----Open products to active account
                DECLARE
                    @ProgramID INT = 9 --Gen mobile
                    , @ProgramTier INT = 9
                INSERT INTO Account.tblAccountProgram
                (
                    AccountID,
                    ProgramID,
                    TierID
                )
                SELECT
                    la.AccountID,
                    @ProgramID AS ProgramID, --Gen mobile
                    @ProgramTier AS ProgramTierID-- Approved Tier 1
                FROM #ListOfAccounts AS la
                WHERE
                    la.AccountID NOT IN
                    (
                        SELECT ap.AccountID
                        FROM Account.tblAccountProgram AS ap
                        WHERE
                            la.AccountID = ap.AccountID
                            AND ap.ProgramID = @ProgramID
                    );

                UPDATE ap
                SET ap.TierID = 9
                FROM Account.tblAccountProgram AS ap
                JOIN #ListOfAccounts AS la ON la.AccountID = ap.AccountID
                WHERE ap.ProgramID = @ProgramID AND ap.TierID <> @ProgramTier


                DECLARE @brandedMPID INT = 11 --gen mobile

                DECLARE
                    @brandedMPTierID INT,
                    @tierLevel INT;

                SELECT @tierLevel = MIN(TierLevel)
                FROM marketplace.tblBrandedMPTiers
                WHERE BrandedMPID = @brandedMPID
                GROUP BY
                    BrandedMPID

                    SELECT @brandedMPTierID = BrandedMPTierID
                    FROM marketplace.tblBrandedMPTiers
                    WHERE
                        BrandedMPID = @brandedMPID
                        AND TierLevel = @tierLevel

                IF
                    EXISTS (
                        SELECT 1 FROM #ListOfAccounts AS la
                        WHERE
                            NOT EXISTS (
                                SELECT abmt.AccountID FROM MarketPlace.tblAccountBrandedMPTier AS abmt
                                WHERE abmt.BrandedMPTierID = @brandedMPTierID AND abmt.AccountID = la.AccountID
                            )
                    )
                    BEGIN
                        MERGE MarketPlace.tblAccountBrandedMPTier AS T
                        USING #ListOfAccounts AS S
                            ON T.AccountID = S.AccountId AND BrandedMPTierID = @brandedMPTierID
                        WHEN NOT MATCHED BY TARGET
                            THEN
                            INSERT (AccountID, BrandedMPID, BrandedMPTierID, DateUpdated, UpdateUserID, Status)
                            VALUES (S.AccountId, @brandedMPID, @brandedMPTierID, GETDATE(), @Username, 1);
                    END

                IF
                    EXISTS (
                        SELECT 1 FROM #ListOfAccounts AS la
                        WHERE
                            NOT EXISTS (
                                SELECT abmb.AccountID FROM MarketPlace.tblAccountBrandedMPBalance AS abmb
                                WHERE abmb.BrandedMPId = @brandedMPID AND abmb.AccountID = la.AccountID
                            )
                    )
                    BEGIN
                        INSERT INTO MarketPlace.tblAccountBrandedMPBalance
                        (AccountID, BrandedMPId, TierLimitTypeId, OutstandingBalance, DateUpdated, UpdateUserID)
                        SELECT
                            la.AccountId,
                            @brandedMPID AS BrandedMPID,
                            tl.TierLimitTypeId,
                            0.00 AS OutstandBalance,
                            GETDATE() AS DateUpdated,
                            @Username AS UpdateUsername
                        FROM #ListOfAccounts AS la, MarketPlace.tblBrandedMPTierLimit AS tl
                        WHERE NOT EXISTS (
                            SELECT abmb.AccountID
                            FROM MarketPlace.tblAccountBrandedMPBalance AS abmb
                            WHERE
                                abmb.BrandedMPId = @brandedMPID
                                AND abmb.AccountID = la.AccountID
                        )
                        AND tl.BrandedMPTierID = @brandedMPTierID
                    END;
            END

            IF (@status IN (8)) --Inactive
                IF
                    NOT EXISTS
                    (
                        SELECT od.account_id
                        FROM dbo.Order_No AS od
                        JOIN dbo.orders AS o
                            ON o.Order_No = od.Order_No
                        JOIN Account.tblProgramTierProducts AS ptp
                            ON
                                ptp.ProductID = o.Product_ID
                                AND ptp.TierID = 26
                        JOIN #ListOfAccounts AS la
                            ON la.AccountID = od.Account_ID
                        WHERE
                            od.OrderType_ID IN (22, 23)
                            AND CAST(od.DateOrdered AS DATE) > DATEADD(DAY, -45, GETDATE())
                    )
                    BEGIN
                        SELECT 'Account has not activated for Cricket in over 45 days' AS [Error Message];
                        RETURN;
                    END


            UPDATE gas
            SET
                gas.StatusID = @status,
                gas.GMStoreID = ISNULL(@GMStoreID, ''),
                gas.Update_Tms = GETDATE()
            OUTPUT
                Inserted.AccountId,
                270 AS CarrierID, --gen mobile
                Deleted.StatusID,
                Inserted.StatusID
            INTO
                Logs.tblAccountStoreLogs
                (
                    AccountID,
                    CarrierID,
                    OldStatusID,
                    NewStatusID
                )
            FROM CarrierSetup.tblGenmobileAccountStore AS gas
            JOIN #ListOfAccounts AS la
                ON la.AccountID = gas.AccountId
            WHERE gas.StatusID <> @status;
        END;



    IF (@status IN (4, 5, 6, 7, 9, 255)) --Closed,Denied,Swap-Closed,Denied by T-Cetra,Closed-Fraud,Ignore/Remove
        BEGIN
            UPDATE gas
            SET
                gas.StatusID = @status,
                gas.Update_Tms = GETDATE()
            OUTPUT
                Inserted.AccountId,
                270 AS CarrierID, --gen mobile
                Deleted.StatusID,
                Inserted.StatusID
            INTO
                Logs.tblAccountStoreLogs
                (
                    AccountID,
                    CarrierID,
                    OldStatusID,
                    NewStatusID
                )
            FROM CarrierSetup.tblGenmobileAccountStore AS gas
            JOIN #ListOfAccounts AS la
                ON la.AccountID = gas.AccountId
            WHERE gas.StatusID <> @status;
        END;

    IF (@status IN (4, 6, 9, 255))		--Closed,Swap-Closed,Closed-Fraud, Ignore/Remove
        BEGIN
            DELETE FROM Account.tblAccountProgram
            WHERE
                ProgramID = @ProgramID
                AND AccountID IN (
                    SELECT AccountID FROM #ListOfAccounts
                )

            DELETE FROM MarketPlace.tblAccountBrandedMPTier
            WHERE
                BrandedMPID = @brandedMPID
                AND AccountID IN (
                    SELECT AccountID FROM #ListOfAccounts
                )
            DELETE FROM MarketPlace.tblAccountBrandedMPBalance
            WHERE
                BrandedMPID = @brandedMPID
                AND AccountID IN (
                    SELECT AccountID FROM #ListOfAccounts
                )

        END;

    SELECT
        la.AccountID,
        ISNULL(tas.Description, 'N/A') AS [Description],
        gas.GMStoreId,
        gas.OutletID,
        gas.TotalMonthlyActivation,
        gas.GMMonthlyActivationForecast,
        gas.PrefLang,
        gas.Comments
    FROM #ListOfAccounts AS la
    LEFT JOIN CarrierSetup.tblGenmobileAccountStore AS gas
        ON gas.AccountId = la.AccountID
    LEFT JOIN CarrierSetup.tblAccountStoreStatus AS tas
        ON tas.StatusID = gas.StatusID;


END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
    RETURN;
END CATCH;
